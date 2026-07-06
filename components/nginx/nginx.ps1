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
    if ($drv -and (Get-Property $drv 'drive')) {
        $drive = Get-Property $drv 'drive'
    } elseif ($drv -and (Get-Property $drv 'appDrive')) {
        $drive = Get-Property $drv 'appDrive'
    } else {
        $drive = "D:"
    }

    $ver = Get-Property $cfg 'version'
    if (-not $ver) { $ver = "1.30.3" }

    $portV = Get-Property $cfg 'port'
    if (-not $portV) { $portV = 80 }

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
                'data'    { $val = 'data\nginx' }
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
    $configDir  = Get-Property $paths 'config'
    $dataDir    = Get-Property $paths 'data'
    $logsDir    = Get-Property $paths 'logs'

    # Symlink 'nginx-current' para facilitar upgrades y referencias sin hardcodear versión
    $nginxBase   = Split-Path $installDir -Parent
    $currentLink = Join-Path $nginxBase "nginx-current"

    $dirsToCreate = @(
        $cache,
        $installDir,
        (Join-Path $installDir 'conf'),
        (Join-Path $installDir 'logs'),
        $configDir,
        $logsDir
    )
    New-Item -ItemType Directory -Path $dirsToCreate -Force | Out-Null

    # Crear carpeta sites-enabled dentro del config persistente
    $sitesEnabled = Join-Path $configDir "sites-enabled"
    New-Item -ItemType Directory -Path $sitesEnabled -Force | Out-Null

    # No creamos www, los frontends se despliegan por sus propios deploy.ps1 a la ubicacion por defecto (D:\www o tools\www segun estructura)

    $exe = Join-Path $installDir "nginx.exe"

    # Si el directorio de instalación existe pero le faltan archivos críticos
    # (puede pasar si se borró mal un symlink anterior), forzamos re-extracción.
    $criticalFile = Join-Path $installDir "conf\mime.types"
    if ((Test-Path $installDir) -and -not (Test-Path $criticalFile)) {
        Write-Host "[nginx] Install directory looks incomplete (missing mime.types). Forcing re-extract..." -ForegroundColor Yellow
        Remove-Item $exe -Force -ErrorAction SilentlyContinue
    }

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

    # Crear/actualizar symlink 'nginx-current' (después de extraer para que el target exista)
    # Eliminar el symlink de forma segura sin seguirlo ni pedir confirmación
    if (Test-Path $currentLink) {
        try {
            $linkItem = Get-Item -LiteralPath $currentLink -Force -ErrorAction Stop
            if ($linkItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                # Borra solo el reparse point (symlink), no el contenido del target
                $linkItem.Delete()
            } else {
                Remove-Item -LiteralPath $currentLink -Force -Recurse -ErrorAction SilentlyContinue
            }
        } catch {
            # Fallback usando cmd (muy confiable para symlinks de directorio)
            cmd /c "rmdir `"$currentLink`" " 2>$null | Out-Null
        }
    }
    try {
        New-Item -ItemType SymbolicLink -Path $currentLink -Target $installDir -Force | Out-Null
        Write-Host "[nginx] Symlink actualizado: tools/nginx-current -> $ver" -ForegroundColor Green
    } catch {
        Write-Host "[nginx] No se pudo crear symlink (requiere Admin o Developer Mode activado). Usa la ruta versionada." -ForegroundColor Yellow
    }

    if ($logsDir) {
        $logP = ([string]$logsDir).TrimEnd('\','/').Replace('/','\')
    } else {
        $logP = 'logs'
    }

    # Usamos el symlink como referencia estable para binarios y archivos estáticos (mime.types, etc.)
    $currentP = ([string]$currentLink).TrimEnd('\','/').Replace('/','\')
    $configP  = ([string]$configDir).TrimEnd('\','/').Replace('/','\')

    # Asegurar que el config dir y sites-enabled existen
    New-Item -ItemType Directory -Path $configDir, $sitesEnabled -Force | Out-Null

    # Asegurar default site con las rutas actuales (lo regeneramos si es necesario)
    $defaultSite = Join-Path $sitesEnabled "default.conf"
    $desiredDefault = @"
server {
    listen       {{port}};
    server_name  localhost;

    location / {
        root   {{currentPath}}/html;
        index  index.html index.htm;
    }

    # Agrega tus propios archivos .conf aquí (vhosts por proyecto)
    # root D:/www/mi-sitio;
}
"@ -replace '{{port}}', $portV -replace '{{currentPath}}', $currentP
    $desiredDefault = $desiredDefault -replace '([A-Za-z]):\\', '$1:/' -replace '\\+', '/'

    # Strip BOM from desired content for comparison/writing
    $desiredDefault = Remove-Utf8Bom $desiredDefault

    $needsDefaultUpdate = $true
    if (Test-Path $defaultSite) {
        $existingDefault = Get-Content $defaultSite -Raw -Encoding UTF8
        $existingDefault = Remove-Utf8Bom $existingDefault
        if ($existingDefault.Trim() -eq $desiredDefault.Trim()) {
            $needsDefaultUpdate = $false
        }
    }

    if ($needsDefaultUpdate) {
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($defaultSite, $desiredDefault, $utf8NoBom)
        Write-Host "[nginx] Updated default site in $defaultSite" -ForegroundColor Green
    }

    # 3. Desplegar la configuración principal en la ruta persistente (config), NO dentro del install versionado
    $tpl = Join-Path $PSScriptRoot "nginx.conf"
    $targetConf = Join-Path $configDir "nginx.conf"

    $content = Get-Content $tpl -Raw -Encoding UTF8
    $content = Remove-Utf8Bom $content

    $logPInConf = $logP -replace '\\\\','/' -replace '\\','/'
    Write-Host "[nginx] Usando config: $targetConf" -ForegroundColor DarkGray
    Write-Host "[nginx] logPath in config: $logPInConf" -ForegroundColor DarkGray

    # Reemplazos usando rutas estables (current + config)
    $content = $content.Replace('{{logPath}}', $logP)
    $content = $content.Replace('{{currentPath}}', $currentP)
    $content = $content.Replace('{{configPath}}', $configP)

    # Normalizar rutas a / (nginx prefiere forward slashes)
    $content = $content -replace '([A-Za-z]):\\', '$1:/'
    $content = $content -replace '\\+', '/'

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
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($targetConf, $content, $utf8NoBom)
        Write-Host "[nginx] Configuration updated at external path." -ForegroundColor Green
    }

    # Asegurar logs dir
    try { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null } catch { }

    # Probar sintaxis usando el symlink 'current' cuando sea posible (facilita que funcione con config externa)
    # Ejecutamos desde el directorio del current link.
    if (Test-Path $currentLink) {
        $testExe = Join-Path $currentLink "nginx.exe"
    } else {
        $testExe = $exe
    }
    if (Test-Path $currentLink) {
        $testDir = $currentLink
    } else {
        $testDir = $installDir
    }
    Push-Location -Path $testDir
    $exitCode = 0
    $testOutput = $null
    try {
        # Ejecutamos nginx -t y capturamos toda la salida (incluyendo stderr)
        $testOutput = & $testExe -t -c $targetConf 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    if ($testOutput) {
        Write-Host "[nginx] nginx -t output:" -ForegroundColor DarkGray
        Write-Host ($testOutput | Out-String).Trim() -ForegroundColor DarkGray
    }

    if ($exitCode -ne 0) {
        Write-Host "[nginx] Configuration error:" -ForegroundColor Red
        throw "[nginx] The configuration has errors (see above)"
    }

    # Feedback limpio cuando pasa (no mostramos el mensaje interno de nginx para no generar ruido)
    Write-Host "[nginx] Configuration syntax: OK" -ForegroundColor Green

    # 4. Servicio - preferimos apuntar al symlink para que los upgrades sean más fáciles (cambias el current y reinicias)
    $svcName = Get-Property (Get-Property $cfg 'service') 'name'
    $useNssm = (Get-Property (Get-Property $cfg 'service') 'useNssm')

    $nssm = "$drive\tools\nssm\nssm.exe"
    $hasNssm = (Test-Path $nssm) -and ($useNssm -ne $false)

    # Usar el symlink para el ejecutable (si existe)
    if (Test-Path $currentLink) {
        $serviceExe = Join-Path $currentLink "nginx.exe"
    } else {
        $serviceExe = $exe
    }

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

        if ($currentApp -ne $serviceExe) {
            & {
                $ErrorActionPreference = 'SilentlyContinue'
                & $nssm stop $svcName 2>&1 | Out-Null
                & $nssm remove $svcName confirm 2>&1 | Out-Null
                & $nssm install $svcName $serviceExe "-c `"$targetConf`"" | Out-Null
                & $nssm set $svcName AppDirectory $currentLink | Out-Null
                & $nssm set $svcName DisplayName (Get-Property (Get-Property $cfg 'service') 'displayName') | Out-Null
                & $nssm set $svcName Start SERVICE_AUTO_START | Out-Null
                & $nssm set $svcName AppStdout (Join-Path $logsDir "stdout.log") | Out-Null
                & $nssm set $svcName AppStderr (Join-Path $logsDir "stderr.log") | Out-Null
                & $nssm set $svcName AppThrottle 1000 | Out-Null
            }
            Write-Host "[nginx] Service configured with NSSM (using current symlink)." -ForegroundColor Green
        }
    } else {
        # Fallback sin NSSM (no recomendado para produccion)
        $existing = Get-Service $svcName -ErrorAction SilentlyContinue
        if (-not $existing) {
            New-Service -Name $svcName `
                        -BinaryPathName "`"$serviceExe`" -c `"$targetConf`"" `
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

    Write-Host "[nginx] Ready: $installDir (current -> $currentLink)" -ForegroundColor Green
    Write-Host "[nginx] Main config: $targetConf" -ForegroundColor Green
    Write-Host "[nginx] Usa facilmente: $currentLink\nginx.exe -c $targetConf" -ForegroundColor DarkGray
}

function Test-NginxComponent {
    param($cfg, $serverCfg, $downloads)
    $drv = $serverCfg
    $drive = if ($drv -and (Get-Property $drv 'drive')) { Get-Property $drv 'drive' } else { "D:" }

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

    # Mostrar rutas útiles (current + config)
    $paths = Get-Property $cfg 'paths'
    if ($paths -and $paths.install) {
        $installGuess = $paths.install
    } else {
        $installGuess = "tools\nginx\*"
    }
    Write-Host "Nginx install (versioned): $drive\$installGuess"
    Write-Host "Uso recomendado: <drive>\tools\nginx\nginx-current\nginx.exe -c <drive>\config\nginx\nginx.conf"
}

function Uninstall-NginxComponent {
    param(
        $cfg,
        $serverCfg,
        $downloads,
        [switch]$WhatIf,
        [switch]$Force,
        [switch]$RemoveConfig,
        [switch]$RemoveLogs,
        [switch]$RemoveData
    )

    $drv = $serverCfg
    $drive = if ($drv -and (Get-Property $drv 'drive')) { Get-Property $drv 'drive' } else { "D:" }

    $ver = Get-Property $cfg 'version'
    if (-not $ver) { $ver = "1.30.3" }

    $paths = Get-Property $cfg 'paths'
    function Get-AbsPath([string]$val, [string]$name, [string]$d, [string]$version) {
        $base = if ($d -match '^[A-Za-z]') { ($d -replace '[:\\/]+$', '') + ':' } else { 'D:' }
        if ($val -and ($val -match '^[A-Za-z]:')) { return ([string]$val).TrimEnd('\','/') }
        if (-not $val -or [string]::IsNullOrWhiteSpace($val)) {
            switch ($name) {
                'install' { $val = if ($version) { "tools\nginx\$version" } else { 'tools\nginx' } }
                'config'  { $val = 'config\nginx' }
                'logs'    { $val = 'logs\nginx' }
            }
        }
        $clean = $val.TrimStart('\','/').Replace('/', '\')
        return (Join-Path $base $clean)
    }

    $installDir = Get-AbsPath (Get-Property $paths 'install') 'install' $drive $ver
    $configDir  = Get-AbsPath (Get-Property $paths 'config')  'config'  $drive $ver
    $logsDir    = Get-AbsPath (Get-Property $paths 'logs')    'logs'    $drive $ver

    $nginxBase   = Split-Path $installDir -Parent
    $currentLink = Join-Path $nginxBase "nginx-current"

    $svcName = Get-Property (Get-Property $cfg 'service') 'name'
    if (-not $svcName) { $svcName = "nginx" }

    $nssm = "$drive\tools\nssm\nssm.exe"

    Write-Host "[nginx] Uninstalling version $ver..." -ForegroundColor Cyan

    # 1. Stop and remove service
    Stop-And-Remove-Service -ServiceName $svcName -NssmPath $nssm

    # 2. Remove symlink
    if (-not $WhatIf) {
        Remove-SymlinkIfExists -Path $currentLink
    } else {
        Write-Host "[nginx] WhatIf: Would remove symlink $currentLink" -ForegroundColor Yellow
    }

    # 3. Remove installed version directory
    if (Test-Path $installDir) {
        if ($WhatIf) {
            Write-Host "[nginx] WhatIf: Would remove $installDir" -ForegroundColor Yellow
        } else {
            $resp = Read-Host "Remove Nginx install dir $installDir ? (y/N)"
            if ($Force -or $resp -eq 'y') {
                Remove-Item $installDir -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "[nginx] Removed: $installDir" -ForegroundColor Green
            }
        }
    }

    # 4. Remove persistent config (only if explicitly requested)
    if ($RemoveConfig -and (Test-Path $configDir)) {
        if ($WhatIf) {
            Write-Host "[nginx] WhatIf: Would remove CONFIG $configDir" -ForegroundColor Yellow
        } else {
            $resp = Read-Host "DANGER: Remove config directory $configDir ? (y/N)"
            if ($Force -or $resp -eq 'y') {
                Remove-Item $configDir -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "[nginx] Removed CONFIG: $configDir" -ForegroundColor Red
            }
        }
    } elseif (Test-Path $configDir) {
        Write-Host "[nginx] Keeping config (use -RemoveConfig to delete): $configDir" -ForegroundColor DarkGray
    }

    # 5. Remove logs (only if requested)
    if ($RemoveLogs -and (Test-Path $logsDir)) {
        if ($WhatIf) {
            Write-Host "[nginx] WhatIf: Would remove logs $logsDir" -ForegroundColor Yellow
        } else {
            $resp = Read-Host "Remove logs $logsDir ? (y/N)"
            if ($Force -or $resp -eq 'y') {
                Remove-Item $logsDir -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "[nginx] Removed logs: $logsDir" -ForegroundColor Green
            }
        }
    } elseif (Test-Path $logsDir) {
        Write-Host "[nginx] Keeping logs: $logsDir" -ForegroundColor DarkGray
    }

    Write-Host "[nginx] Uninstall finished for Nginx." -ForegroundColor Green
}

# Note: dot-sourced from deploy.ps1, Export-ModuleMember not needed
