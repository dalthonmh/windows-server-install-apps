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
        # Remove UTF-8 BOM (0xFEFF) if present at the start
        if ($text.Length -gt 0 -and [int][char]$text[0] -eq 0xFEFF) {
            $text = $text.Substring(1)
        }
        # Fallback for literal mangled BOM (ï»¿)
        if ($text.StartsWith("ï»¿")) {
            $text = $text.Substring(3)
        }
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

    # Paths: config is now INSIDE the nginx install (conf/nginx.conf + conf/sites-enabled)
    # No external D:\config\nginx anymore.
    $paths = Get-Property $cfg 'paths'
    function Get-AbsPath([string]$val, [string]$name, [string]$d, [string]$version) {
        $base = if ($d -match '^[A-Za-z]') { ($d -replace '[:\\/]+$', '') + ':' } else { 'D:' }
        if ($val -and ($val -match '^[A-Za-z]:')) { return ([string]$val).TrimEnd('\','/') }
        if (-not $val -or [string]::IsNullOrWhiteSpace($val)) {
            switch ($name) {
                'install' { $val = if ($version) { "tools\nginx\$version" } else { 'tools\nginx' } }
                'logs'    { $val = 'logs\nginx' }
            }
        }
        $clean = $val.TrimStart('\','/').Replace('/', '\')
        return (Join-Path $base $clean)
    }

    $installP = Get-Property $paths 'install'
    $logsP    = Get-Property $paths 'logs'

    $paths = @{
        install = Get-AbsPath $installP 'install' $drive $ver
        logs    = Get-AbsPath $logsP    'logs'    $drive $ver
    }

    $cache = "$drive\downloads\cache"

    # Crear TODAS las carpetas necesarias de forma defensiva y temprana.
    # Esto evita la mayoria de errores "no se puede encontrar la ruta/archivo" (como mime.types, logs, etc.)
    # durante la prueba de configuracion o al arrancar el servicio.
    $installDir = Get-Property $paths 'install'
    $logsDir    = Get-Property $paths 'logs'

    # Symlink 'nginx-current' para facilitar upgrades y referencias sin hardcodear versión
    $nginxBase   = Split-Path $installDir -Parent
    $currentLink = Join-Path $nginxBase "nginx-current"

    # Dirs: everything (conf + sites-enabled) lives inside the install/current dir now.
    $dirsToCreate = @(
        $cache,
        $installDir,
        (Join-Path $installDir 'conf'),
        (Join-Path $installDir 'conf\sites-enabled'),
        (Join-Path $installDir 'logs'),
        $logsDir
    )
    New-Item -ItemType Directory -Path $dirsToCreate -Force | Out-Null

    # No creamos www, los frontends se despliegan por sus propios deploy.ps1...

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

    # Usamos el symlink como referencia estable (todo config ahora dentro de current/conf)
    $currentP = ([string]$currentLink).TrimEnd('\','/').Replace('/','\')

    # sites-enabled ahora vive dentro de la instalacion (conf/sites-enabled)
    $sitesEnabled = Join-Path $installDir "conf\sites-enabled"

    # If default.conf has a UTF-8 BOM on disk, delete it so we force a clean write
    $defaultSiteTemp = Join-Path $sitesEnabled "default.conf"
    if (Test-Path $defaultSiteTemp) {
        $b = [System.IO.File]::ReadAllBytes($defaultSiteTemp)
        if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) {
            Remove-Item $defaultSiteTemp -Force -ErrorAction SilentlyContinue
            Write-Host "[nginx] Removed BOM-corrupted default.conf to force clean rewrite." -ForegroundColor Yellow
        }
    }

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

    # Agrega tus propios archivos .conf aquí (vhosts por proyecto) dentro de conf/sites-enabled/
    # root D:/www/mi-sitio;
}
"@ -replace '{{port}}', $portV -replace '{{currentPath}}', $currentP
    $desiredDefault = $desiredDefault -replace '([A-Za-z]):\\', '$1:/' -replace '\\+', '/'

    # Strip BOM from desired content for comparison/writing
    $desiredDefault = Remove-Utf8Bom $desiredDefault

    $needsDefaultUpdate = $true
    if (Test-Path $defaultSite) {
        # Check raw bytes for UTF-8 BOM (EF BB BF) - most reliable
        $bytes = [System.IO.File]::ReadAllBytes($defaultSite)
        $hasBomBytes = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)

        $rawExisting = Get-Content $defaultSite -Raw -Encoding UTF8
        $hadBom = $hasBomBytes -or ($rawExisting.Length -gt 0 -and ([int][char]$rawExisting[0] -eq 0xFEFF -or $rawExisting.StartsWith("ï»¿")))
        $existingDefault = Remove-Utf8Bom $rawExisting
        if (-not $hadBom -and ($existingDefault.Trim() -eq $desiredDefault.Trim())) {
            $needsDefaultUpdate = $false
        }
    }

    if ($needsDefaultUpdate) {
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($defaultSite, $desiredDefault, $utf8NoBom)
        Write-Host "[nginx] Updated default site in $defaultSite (no BOM)" -ForegroundColor Green
    }

    # 3. Config principal DENTRO del install (conf/nginx.conf). Sin carpeta externa config/
    $tpl = Join-Path $PSScriptRoot "nginx.conf"
    $targetConf = Join-Path $installDir "conf\nginx.conf"

    # Pre-clean main config if it has BOM
    if (Test-Path $targetConf) {
        $b = [System.IO.File]::ReadAllBytes($targetConf)
        if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) {
            Remove-Item $targetConf -Force -ErrorAction SilentlyContinue
            Write-Host "[nginx] Removed BOM from main nginx.conf." -ForegroundColor Yellow
        }
    }

    $content = Get-Content $tpl -Raw -Encoding UTF8
    $content = Remove-Utf8Bom $content

    $logPInConf = $logP -replace '\\\\','/' -replace '\\','/'
    Write-Host "[nginx] Usando config: $targetConf" -ForegroundColor DarkGray
    Write-Host "[nginx] logPath in config: $logPInConf" -ForegroundColor DarkGray

    # Reemplazos: configPath ahora apunta dentro de current/conf (para el include de sites-enabled)
    $internalConfigP = "$currentP/conf"
    $content = $content.Replace('{{logPath}}', $logP)
    $content = $content.Replace('{{currentPath}}', $currentP)
    $content = $content.Replace('{{configPath}}', $internalConfigP)

    # Normalizar rutas a / (nginx prefiere forward slashes)
    $content = $content -replace '([A-Za-z]):\\', '$1:/'
    $content = $content -replace '\\+', '/'

    $content = Remove-Utf8Bom $content
    $content = $content.TrimStart([char]0xFEFF)

    $needsUpdate = $true
    if (Test-Path $targetConf) {
        $rawCurrent = Get-Content $targetConf -Raw -Encoding UTF8
        $hadBomMain = $rawCurrent.Length -gt 0 -and ([int][char]$rawCurrent[0] -eq 0xFEFF -or $rawCurrent.StartsWith("ï»¿"))
        $current = Remove-Utf8Bom $rawCurrent
        $current = $current.TrimStart([char]0xFEFF)
        if (-not $hadBomMain -and ($current -eq $content)) {
            $needsUpdate = $false
        }
    }

    if ($needsUpdate) {
        Copy-Item $targetConf "$targetConf.bak" -ErrorAction SilentlyContinue -Force
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($targetConf, $content, $utf8NoBom)
        Write-Host "[nginx] Configuration updated inside install (no external config folder)." -ForegroundColor Green
    }

    # Asegurar logs dir
    try { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null } catch { }

    # Probar sintaxis usando el symlink 'current'. Config esta dentro de conf/
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
        $testOutput = & {
            $ErrorActionPreference = 'SilentlyContinue'
            cmd /c "`"$testExe`" -t -c `"conf\nginx.conf`"" 2>&1
        }
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    if ($exitCode -ne 0) {
        Write-Host "[nginx] Configuration error:" -ForegroundColor Red
        if ($testOutput) {
            Write-Host ($testOutput | Out-String).Trim() -ForegroundColor Red
        }
        throw "[nginx] The configuration has errors (see above)"
    }

    # Feedback limpio cuando pasa
    Write-Host "[nginx] Configuration syntax: OK" -ForegroundColor Green

    # NO registramos el servicio directamente con NSSM aqui.
    # En su lugar generamos scripts para que el usuario los ejecute (apuntando a *-current).
    $svcName = Get-Property (Get-Property $cfg 'service') 'name'
    if (-not $svcName) { $svcName = "nginx" }

    # Crear scripts/ con helper para instalar el servicio via NSSM + wrapper simple
    $scriptsDir = Join-Path $installDir "scripts"
    New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null

    # Script de setup del servicio (ejecutar como Admin). Siempre usa el current symlink.
    $setupScript = Join-Path $scriptsDir "setup-nginx-service.ps1"
    $setupContent = @"
# Auto-generado por deploy.ps1 - $(Get-Date -Format 'yyyy-MM-dd HH:mm')
# Ejecuta este script como ADMINISTRADOR para registrar $svcName como servicio con NSSM.
# Apunta SIEMPRE a la carpeta current para que los upgrades sean faciles (solo actualiza el symlink).

param(
    [string]`$Nssm = "nssm"
)

`$current   = "$currentLink"
`$exe       = Join-Path `$current "nginx.exe"
`$appDir    = `$current
`$params    = "-c conf\nginx.conf"

`$logDir    = "$logsDir"
`$stdoutLog = if (`$logDir) { Join-Path `$logDir "stdout.log" } else { Join-Path `$current "logs\stdout.log" }
`$stderrLog = if (`$logDir) { Join-Path `$logDir "stderr.log" } else { Join-Path `$current "logs\stderr.log" }

Write-Host "Configurando servicio NSSM para Nginx (current: `$current)..." -ForegroundColor Cyan

& `$Nssm stop $svcName 2>`$null | Out-Null
& `$Nssm remove $svcName confirm 2>`$null | Out-Null

& `$Nssm install $svcName "`$exe" | Out-Null
& `$Nssm set $svcName AppDirectory "`$appDir" | Out-Null
& `$Nssm set $svcName AppParameters "`$params" | Out-Null
& `$Nssm set $svcName DisplayName "Nginx Web Server" | Out-Null
& `$Nssm set $svcName Description "Nginx Web Server" | Out-Null
& `$Nssm set $svcName Start SERVICE_AUTO_START | Out-Null
& `$Nssm set $svcName AppStdout "`$stdoutLog" | Out-Null
& `$Nssm set $svcName AppStderr "`$stderrLog" | Out-Null
& `$Nssm set $svcName AppThrottle 1000 | Out-Null

Write-Host "Listo. Inicia con: nssm start $svcName   (o net start $svcName)" -ForegroundColor Green
Write-Host "Para ver config: nssm get $svcName AppParameters" -ForegroundColor DarkGray
"@
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($setupScript, $setupContent, $utf8NoBom)
    Write-Host "[nginx] Script para instalar servicio creado: $setupScript" -ForegroundColor Green
    Write-Host "        Ejecutalo manualmente como Admin cuando quieras registrar/actualizar el servicio." -ForegroundColor DarkGray

    # Wrapper simple run.bat (puede usarse con NSSM o para pruebas manuales)
    $runBat = Join-Path $installDir "run.bat"
    $runBatContent = @"
@echo off
cd /d "%~dp0"
echo Iniciando Nginx desde %CD% (apuntando a current config)...
nginx.exe -c conf\nginx.conf
"@
    [System.IO.File]::WriteAllText($runBat, $runBatContent, $utf8NoBom)

    Write-Host "[nginx] Ready: $installDir (current -> $currentLink)" -ForegroundColor Green
    Write-Host "[nginx] Main config (inside current): $targetConf" -ForegroundColor Green
    Write-Host "[nginx] Para servicio: ejecuta $scriptsDir\setup-nginx-service.ps1 (como Admin)" -ForegroundColor DarkGray
    Write-Host "[nginx] O apunta NSSM al exe + -c conf\nginx.conf con AppDirectory = current" -ForegroundColor DarkGray
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
    Write-Host "Uso recomendado (config dentro de current):"
    Write-Host "  cd /d <drive>\tools\nginx\nginx-current"
    Write-Host "  nginx.exe -c conf\nginx.conf"
    Write-Host "  (o ejecuta el script scripts\setup-nginx-service.ps1 como Admin para NSSM)"
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
                'config'  { $val = 'config\nginx' } # solo legacy
                'logs'    { $val = 'logs\nginx' }
            }
        }
        $clean = $val.TrimStart('\','/').Replace('/', '\')
        return (Join-Path $base $clean)
    }

    $installDir = Get-AbsPath (Get-Property $paths 'install') 'install' $drive $ver
    $logsDir    = Get-AbsPath (Get-Property $paths 'logs')    'logs'    $drive $ver

    # Legacy external config dir (only for RemoveConfig on old installs). New installs keep config inside installDir.
    $legacyConfigDir = $null
    $oldCfgP = Get-Property $paths 'config'
    if ($oldCfgP) {
        $legacyConfigDir = Get-AbsPath $oldCfgP 'config' $drive $ver
    }

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

    # 4. Legacy external config (D:\config\nginx) only removed if -RemoveConfig and exists.
    #    New config lives inside the install dir (removed together with the version dir).
    if ($legacyConfigDir -and $RemoveConfig -and (Test-Path $legacyConfigDir)) {
        if ($WhatIf) {
            Write-Host "[nginx] WhatIf: Would remove LEGACY CONFIG $legacyConfigDir" -ForegroundColor Yellow
        } else {
            $resp = Read-Host "DANGER: Remove legacy config directory $legacyConfigDir ? (y/N)"
            if ($Force -or $resp -eq 'y') {
                Remove-Item $legacyConfigDir -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "[nginx] Removed LEGACY CONFIG: $legacyConfigDir" -ForegroundColor Red
            }
        }
    } elseif ($legacyConfigDir -and (Test-Path $legacyConfigDir)) {
        Write-Host "[nginx] Keeping legacy config dir (use -RemoveConfig to delete): $legacyConfigDir" -ForegroundColor DarkGray
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
