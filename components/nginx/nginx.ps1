# Componente Nginx - Logica de instalacion
# Se carga dinamicamente desde deploy.ps1

function Get-Property($obj, [string]$name) {
    if ($null -eq $obj -or [string]::IsNullOrEmpty($name)) { return $null }
    if ($obj -is [hashtable]) {
        if ($obj.ContainsKey($name)) { return $obj[$name] }
        return $null
    }
    if ($obj -is [System.Collections.IDictionary]) {
        if ($obj.Contains($name)) { return $obj[$name] }
        return $null
    }
    if ($obj -is [psobject]) {
        $prop = $obj.PSObject.Properties[$name]
        if ($prop) { return $prop.Value }
        return $null
    }
    return $null
}

function Install-NginxComponent {
    param($cfg, $serverCfg, $downloads)

    function Remove-Utf8Bom([string]$text) {
        if ([string]::IsNullOrEmpty($text)) { return $text }
        # Quitar BOM UTF-8 si esta presente (causa "unknown directive ï»¿#" en nginx)
        if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) {
            return $text.Substring(1)
        }
        # Por si viene como caracteres literales ï»¿ (cuando se lee mal)
        if ($text.StartsWith("ï»¿")) { return $text.Substring(3) }
        return $text
    }

    $drv = $serverCfg
    $drive = if ($drv -and (Get-Property $drv 'drive')) { Get-Property $drv 'drive' } 
             elseif ($drv -and (Get-Property $drv 'appDrive')) { Get-Property $drv 'appDrive' } 
             else { "D:" }

    $ver = Get-Property $cfg 'version'
    if (-not $ver) { $ver = "1.30.3" }

    # Base de descargas (estaticos)
    $base = $null
    if ($downloads) { $base = Get-Property $downloads 'base' }
    if (-not $base) { $base = "https://dalthonmh.com/bin" }

    $url = Get-Property $cfg 'url'
    if (-not $url) {
        $url = "$base/nginx-$ver.zip"
    }

    # Obtener paths del config o defaults, y normalizar SIEMPRE a rutas absolutas
    $paths = Get-Property $cfg 'paths'
    function Get-AbsPath([string]$val, [string]$name, [string]$d, [string]$version) {
        $base = if ($d -match '^[A-Za-z]') { ($d -replace '[:\\/]+$', '') + ':' } else { 'D:' }
        if ($val -and ($val -match '^[A-Za-z]:')) { return ([string]$val).TrimEnd('\','/') }
        if (-not $val -or [string]::IsNullOrWhiteSpace($val)) {
            switch ($name) {
                'install' { $val = if ($version) { "tools\nginx\$version" } else { 'tools\nginx' } }
                'config'  { $val = 'config\nginx' }
                'data'    { $val = 'www' }
                'logs'    { $val = 'logs\nginx' }
            }
        }
        $clean = $val.TrimStart('\','/').Replace('/', '\')
        return (Join-Path $base $clean)
    }

    $installP = Get-Property $paths 'install'
    $configP  = Get-Property $paths 'config'
    $dataP    = Get-Property $paths 'data'
    $logsP    = Get-Property $paths 'logs'

    $paths = @{
        install = Get-AbsPath $installP 'install' $drive $ver
        config  = Get-AbsPath $configP  'config'  $drive $ver
        data    = Get-AbsPath $dataP    'data'    $drive $ver
        logs    = Get-AbsPath $logsP    'logs'    $drive $ver
    }

    $cache = "$drive\downloads\cache"

    # Crear TODAS las carpetas necesarias de forma defensiva y temprana.
    # Esto evita la mayoria de errores "no se puede encontrar la ruta/archivo" (como mime.types, logs, etc.)
    # durante la prueba de configuracion o al arrancar el servicio.
    $installDir = Get-Property $paths 'install'
    $dirsToCreate = @(
        $cache,
        $installDir,
        (Get-Property $paths 'config'),
        (Join-Path $installDir 'conf'),
        (Join-Path $installDir 'logs'),
        (Get-Property $paths 'data'),
        (Get-Property $paths 'logs')
    )
    New-Item -ItemType Directory -Path $dirsToCreate -Force | Out-Null

    # Crear carpeta www + index basico si no existe (separacion de datos)
    $www = Join-Path (Get-Property $paths 'data') "www"
    New-Item -ItemType Directory -Path $www -Force | Out-Null
    $index = Join-Path $www "index.html"
    if (-not (Test-Path $index)) {
        '<em>Thank you for using nginx.</em>' | Out-File $index -Encoding utf8
    }

    $exe = Join-Path (Get-Property $paths 'install') "nginx.exe"

    # 1. Descargar usando caché compartida (solo una vez por versión)
    $zip = Get-CachedDownload -Url $url -CacheDir $cache -FileName "nginx-$ver.zip" -Label "[nginx]"

    # 2. Extraer solo si no existe (idempotencia)
    if (-not (Test-Path $exe)) {
        Write-Host "[nginx] Extracting version $ver..." -ForegroundColor Cyan
        $installPath = Get-Property $paths 'install'

        # Limpiar cualquier subcarpeta nginx-* residual de extracciones previas
        Get-ChildItem $installPath -Directory -Force | Where-Object { $_.Name -like "nginx*" } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

        try {
            Expand-Archive -Path $zip -DestinationPath $installPath -Force

            # El zip suele crear nginx-1.30.3\, lo movemos al nivel superior
            $sub = Get-ChildItem $installPath -Directory | Where-Object { $_.Name -like "nginx*" } | Select-Object -First 1
            if ($sub) {
                # Eliminar destinos existentes para evitar "No se puede crear un archivo que ya existe"
                Get-ChildItem $sub.FullName | ForEach-Object {
                    $dest = Join-Path $installPath $_.Name
                    if (Test-Path $dest) {
                        Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    Move-Item $_.FullName -Destination $installPath -Force
                }
                Remove-Item $sub.FullName -Recurse -Force
            }
        } catch {
            Write-Host "[nginx] Extract failed (bad or corrupted zip). Removing from cache." -ForegroundColor Red
            Remove-Item $zip -Force -ErrorAction SilentlyContinue
            throw
        }
    }

    # Asegurar archivos de soporte (mime.types y similares) en la carpeta de config
    # (util cuando se separa config de la instalacion de nginx)
    $installConfDir = Join-Path (Get-Property $paths 'install') 'conf'
    $targetConfDir  = Get-Property $paths 'config'
    if (Test-Path $installConfDir) {
        $supportFiles = @('mime.types', 'fastcgi_params', 'uwsgi_params', 'scgi_params')
        foreach ($f in $supportFiles) {
            $src = Join-Path $installConfDir $f
            if (Test-Path $src) {
                Copy-Item $src (Join-Path $targetConfDir $f) -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # Asegurar que sites-enabled exista para vhosts por cliente/sistema
    $sitesEnabled = Join-Path $targetConfDir "sites-enabled"
    New-Item -ItemType Directory -Path $sitesEnabled -Force | Out-Null

    # 3. Desplegar configuracion (solo si cambio)
    $tpl = Join-Path $PSScriptRoot "nginx.conf"
    $targetConf = Join-Path (Get-Property $paths 'config') "nginx.conf"

    $content = Get-Content $tpl -Raw -Encoding UTF8
    $content = Remove-Utf8Bom $content

    $logPRaw     = Get-Property $paths 'logs'
    $dataPRaw    = Get-Property $paths 'data'
    $installPRaw = Get-Property $paths 'install'
    $configPRaw  = Get-Property $paths 'config'
    $portV       = Get-Property $cfg 'port'

    # Usar rutas absolutas (ya normalizadas arriba). Forzar backslashes para claridad
    $logP     = if ($logPRaw)     { ([string]$logPRaw).TrimEnd('\','/').Replace('/','\') } else { 'logs' }
    $dataP    = if ($dataPRaw)    { ([string]$dataPRaw).TrimEnd('\','/').Replace('/','\') } else { 'data' }
    $installP = if ($installPRaw) { ([string]$installPRaw).TrimEnd('\','/').Replace('/','\') } else { '' }
    $configP  = if ($configPRaw)  { ([string]$configPRaw).TrimEnd('\','/').Replace('/','\') } else { 'D:\config\nginx' }

    # Asegurar que existan las carpetas necesarias (config + logs custom)
    try { New-Item -ItemType Directory -Path $logPRaw -Force | Out-Null } catch { }
    try { New-Item -ItemType Directory -Path (Split-Path $targetConf -Parent) -Force | Out-Null } catch { }

    # Crear sites-enabled para vhosts por cliente/sistema
    $sitesEnabled = Join-Path $configP "sites-enabled"
    New-Item -ItemType Directory -Path $sitesEnabled -Force | Out-Null

    # Reemplazos con String.Replace usando rutas Windows (backslashes)
    $content = $content.Replace('{{logPath}}', $logP)
    $content = $content.Replace('{{dataPath}}', $dataP)
    $content = $content.Replace('{{installPath}}', $installP)
    $content = $content.Replace('{{configPath}}', $configP)
    $content = $content.Replace('{{port}}', [string]$portV)

    # Normalizar todas las rutas generadas a usar / (estilo recomendado para nginx, funciona perfecto en Windows)
    $content = $content -replace '([A-Za-z]):\\', '$1:/'
    $content = $content -replace '\\+', '/'

    # Limpiar cualquier BOM residual antes de escribir/comparar
    $content = Remove-Utf8Bom $content
    $content = $content.TrimStart([char]0xFEFF)

    $needsUpdate = $true
    if (Test-Path $targetConf) {
        $current = Get-Content $targetConf -Raw -Encoding UTF8
        $current = Remove-Utf8Bom $current
        $current = $current.TrimStart([char]0xFEFF)
        if ($current -eq $content) { $needsUpdate = $false }
    }

    if ($needsUpdate) {
        Copy-Item $targetConf "$targetConf.bak" -ErrorAction SilentlyContinue -Force
        # Escribir SIN BOM (Set-Content -Encoding UTF8 agrega BOM en PS 5.1 y nginx lo odia)
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($targetConf, $content, $utf8NoBom)
        Write-Host "[nginx] Configuration updated." -ForegroundColor Green
    }

    $logPInConf = $logP -replace '\\\\','/' -replace '\\','/'
    $dataPInConf = $dataP -replace '\\\\','/' -replace '\\','/'
    Write-Host "[nginx] logPath in config: $logPInConf" -ForegroundColor DarkGray
    Write-Host "[nginx] dataPath in config: $dataPInConf" -ForegroundColor DarkGray

    # Asegurar que los directorios referenciados en la config existen (error_log, access_log, pid)
    try {
        # Siempre asegurar el logPath y dataPath que calculamos (lo mas importante)
        if ($logP) {
            $lp = $logP -replace '/','\'
            $ld = if ($lp -match '^[A-Za-z]:') { Split-Path $lp -Parent } else { $lp }
            try { New-Item -ItemType Directory -Path $ld -Force | Out-Null } catch {}
        }
        if ($dataP) {
            $dp = $dataP -replace '/','\'
            $dd = if ($dp -match '^[A-Za-z]:') { Join-Path $dp 'www' } else { $dp }
            try { New-Item -ItemType Directory -Path $dd -Force | Out-Null } catch {}
        }

        # Fallback legacy por si la config tiene rutas relativas
        $cfgDir = Split-Path $targetConf -Parent
        $errPath = $null
        if ($content -match 'error_log\s+"(?<p>[^\"]+)"') { $errPath = $Matches['p'] } elseif ($content -match "error_log\s+(?<p>[^\s;]+)") { $errPath = $Matches['p'] }
        if ($errPath) {
            $errPathNorm = $errPath -replace '/','\\'
            if (-not ($errPathNorm -match '^[A-Za-z]:\\')) { $errFull = Join-Path $cfgDir $errPathNorm } else { $errFull = $errPathNorm }
            $errDir = Split-Path $errFull -Parent
            try { New-Item -ItemType Directory -Path $errDir -Force | Out-Null } catch { }
        }
    } catch { }

    # Probar sintaxis (compatible PS 5.1)
    # Ejecutamos desde el directorio de nginx.exe para que cualquier ruta relativa se resuelva bien.
    # nginx escribe los mensajes de "syntax is ok" a stderr incluso en exito.
    # Usamos un scriptblock con $ErrorActionPreference='SilentlyContinue' local para que
    # PowerShell (que tiene Stop a nivel global) no convierta esos mensajes en NativeCommandError.
    $installDir = Get-Property $paths 'install'
    Push-Location -Path $installDir
    try {
        # Ejecutar en un scriptblock con EA local para que los mensajes de stderr de nginx
        # (incluso los de exito) no generen ErrorRecords visibles.
        $testOutput = & {
            $ErrorActionPreference = 'SilentlyContinue'
            & $exe -t -c $targetConf 2>&1
        }
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    if ($exitCode -ne 0) {
        Write-Host "[nginx] Configuration error:" -ForegroundColor Red
        Write-Host ($testOutput | Out-String) -ForegroundColor Red
        throw "[nginx] The configuration has errors (see above)"
    }

    # Feedback limpio cuando pasa (no mostramos el mensaje interno de nginx para no generar ruido)
    Write-Host "[nginx] Configuration syntax: OK" -ForegroundColor Green

    # 4. Servicio
    $svcName = Get-Property (Get-Property $cfg 'service') 'name'
    $useNssm = (Get-Property (Get-Property $cfg 'service') 'useNssm')

    $nssm = "$drive\apps\nssm\nssm.exe"
    $hasNssm = (Test-Path $nssm) -and ($useNssm -ne $false)

    if ($hasNssm) {
        # Usamos NSSM (debe haber sido instalado por el componente nssm separado)
        $existingSvc = Get-Service $svcName -ErrorAction SilentlyContinue

        $currentApp = $null
        if ($existingSvc) {
            $currentApp = & {
                $ErrorActionPreference = 'SilentlyContinue'
                & $nssm get $svcName Application 2>&1
            }
        }

        if ($currentApp -ne $exe) {
            & {
                $ErrorActionPreference = 'SilentlyContinue'
                & $nssm stop $svcName 2>&1 | Out-Null
                & $nssm remove $svcName confirm 2>&1 | Out-Null
                & $nssm install $svcName $exe "-c `"$targetConf`"" | Out-Null
                & $nssm set $svcName AppDirectory (Get-Property $paths 'install') | Out-Null
                & $nssm set $svcName DisplayName (Get-Property (Get-Property $cfg 'service') 'displayName') | Out-Null
                & $nssm set $svcName Start SERVICE_AUTO_START | Out-Null
            }
            Write-Host "[nginx] Service configured with NSSM." -ForegroundColor Green
        }
    } else {
        # Fallback sin NSSM (no recomendado para produccion)
        $existing = Get-Service $svcName -ErrorAction SilentlyContinue
        if (-not $existing) {
            New-Service -Name $svcName `
                        -BinaryPathName "`"$exe`" -c `"$targetConf`"" `
                        -DisplayName (Get-Property (Get-Property $cfg 'service') 'displayName') `
                        -StartupType Automatic | Out-Null
            Write-Host "[nginx] Service registered (without NSSM)." -ForegroundColor Yellow
        }
    }

    # Iniciar
    $svc = Get-Service $svcName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Running') {
        Start-Service $svcName -ErrorAction SilentlyContinue
    }

    Write-Host "[nginx] Ready: $(Get-Property $paths 'install')" -ForegroundColor Green
}

function Test-NginxComponent {
    param($cfg, $serverCfg, $downloads)
    $svcName = Get-Property (Get-Property $cfg 'service') 'name'
    $port = Get-Property $cfg 'port'

    $svc = Get-Service $svcName -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Host ("Service {0} : {1}" -f $svcName, $svc.Status)
    } else {
        Write-Host "Service $svcName : DOES NOT EXIST"
    }

    try {
        $resp = Invoke-WebRequest "http://localhost:$port" -TimeoutSec 6 -UseBasicParsing
        Write-Host "HTTP port $port : OK ($($resp.StatusCode))"
    } catch {
        Write-Host "HTTP port $port : No response or error"
    }
}

# Note: dot-sourced from deploy.ps1, Export-ModuleMember not needed
