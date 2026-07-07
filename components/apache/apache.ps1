# Componente Apache (Apache Lounge) + integracion basica con PHP
# Corre en puerto 81 por defecto (para no chocar con Nginx en 80)

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

function Install-ApacheComponent {
    param($cfg, $serverCfg, $downloads)

    $drv = $serverCfg
    $drive = if ($drv -and (Get-Property $drv 'drive')) { Get-Property $drv 'drive' } 
             elseif ($drv -and (Get-Property $drv 'appDrive')) { Get-Property $drv 'appDrive' } 
             else { "D:" }

    $ver = Get-Property $cfg 'version'
    if (-not $ver) { $ver = "2.4.68" }

    $base = $null
    if ($downloads) { $base = Get-Property $downloads 'base' }
    if (-not $base) { $base = "https://dalthonmh.com/bin" }

    $url = Get-Property $cfg 'url'
    if (-not $url) {
        $url = "$base/httpd-$ver.zip"
    }

    $port = Get-Property $cfg 'port'
    if (-not $port) { $port = 81 }

    # Paths
    $paths = Get-Property $cfg 'paths'
    function Get-AbsPath([string]$val, [string]$name, [string]$d, [string]$version) {
        $base = if ($d -match '^[A-Za-z]') { ($d -replace '[:\\/]+$', '') + ':' } else { 'D:' }
        if ($val -and ($val -match '^[A-Za-z]:')) { return ([string]$val).TrimEnd('\','/') }
        if (-not $val -or [string]::IsNullOrWhiteSpace($val)) {
            switch ($name) {
                'install' { $val = if ($version) { "tools\apache\$version" } else { 'tools\apache' } }
                'logs'    { $val = 'logs\apache' }
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

    $installDir = Get-Property $paths 'install'
    $dirsToCreate = @(
        $cache,
        $installDir,
        (Get-Property $paths 'logs')
    )
    New-Item -ItemType Directory -Path $dirsToCreate -Force | Out-Null

    # Usamos los htdocs por defecto dentro del install de apache (no creamos carpeta www separada)
    $htdocs = Join-Path $installDir "htdocs"
    New-Item -ItemType Directory -Path $htdocs -Force | Out-Null
    $indexHtml = Join-Path $htdocs "index.html"
    if (-not (Test-Path $indexHtml)) {
        '<h1>It works! (Apache on port 81)</h1>' | Out-File $indexHtml -Encoding utf8
    }

    $indexPhp = Join-Path $htdocs "index.php"
    if (-not (Test-Path $indexPhp)) {
        '<?php phpinfo(); ?>' | Out-File $indexPhp -Encoding utf8
    }

    $httpdExe = Join-Path $installDir "bin\httpd.exe"

    # 1. Descargar usando caché compartida (solo una vez por versión)
    $zip = Get-CachedDownload -Url $url -CacheDir $cache -FileName "httpd-$ver.zip" -Label "[apache]"

    # 2. Extraer
    if (-not (Test-Path $httpdExe)) {
        Write-Host "[apache] Extracting version $ver..." -ForegroundColor Cyan

        # Limpiar residual
        Get-ChildItem $installDir -Directory -Force | Where-Object { $_.Name -like "*apache*" -or $_.Name -like "*httpd*" } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

        try {
            Expand-Archive -Path $zip -DestinationPath $installDir -Force

            # Mover contenido si el zip crea subcarpeta (ej Apache24 o httpd-2.4.68)
            $sub = Get-ChildItem $installDir -Directory | Where-Object { 
                $_.Name -like "*apache*" -or $_.Name -like "*httpd*" -or $_.Name -like "Apache*" 
            } | Select-Object -First 1

            if ($sub) {
                Get-ChildItem $sub.FullName | Move-Item -Destination $installDir -Force
                Remove-Item $sub.FullName -Recurse -Force
            }
        } catch {
            Write-Host "[apache] Extract failed (bad or corrupted zip). Removing from cache so it will be re-downloaded next time." -ForegroundColor Red
            Remove-Item $zip -Force -ErrorAction SilentlyContinue
            throw "[apache] Could not extract Apache. Bad download was cleaned; re-run deploy.ps1."
        }
    }

    # Crear/actualizar symlink 'apache-current' (despues de extraer)
    $apacheBase   = Split-Path $installDir -Parent
    $currentLink = Join-Path $apacheBase "apache-current"

    if (Test-Path $currentLink) {
        try {
            $linkItem = Get-Item -LiteralPath $currentLink -Force -ErrorAction Stop
            if ($linkItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                $linkItem.Delete()
            } else {
                Remove-Item -LiteralPath $currentLink -Force -Recurse -ErrorAction SilentlyContinue
            }
        } catch {
            cmd /c "rmdir `"$currentLink`" " 2>$null | Out-Null
        }
    }
    try {
        New-Item -ItemType SymbolicLink -Path $currentLink -Target $installDir -Force | Out-Null
        Write-Host "[apache] Symlink actualizado: apache-current -> $ver" -ForegroundColor Green
    } catch {
        Write-Host "[apache] No se pudo crear symlink (requiere Admin o Developer Mode activado). Usa la ruta versionada." -ForegroundColor Yellow
    }

    # 3. Configurar httpd.conf (puerto + PHP basico) - el archivo queda DENTRO del apache (conf/httpd.conf)
    $httpdConf = Join-Path $installDir "conf\httpd.conf"
    if (Test-Path $httpdConf) {
        $content = Get-Content $httpdConf -Raw

        # Set ServerRoot correctly
        $content = $content -replace '(?m)^ServerRoot\s+.*$', "ServerRoot `"$installDir`""

        # Set DocumentRoot to our htdocs (inside the apache install)
        $htdocs = Join-Path $installDir "htdocs"
        $content = $content -replace '(?m)^DocumentRoot\s+.*$', "DocumentRoot `"$htdocs`""
        $content = $content -replace '(?m)^<Directory\s+[^>]+>', "<Directory `"$htdocs`">"

        # Cambiar Listen al puerto deseado
        $content = $content -replace '(?m)^Listen\s+.*$', "Listen $port"

        # Agregar configuracion de PHP si no existe todavia
        if ($content -notmatch 'php-cgi') {
            # Intentar detectar php instalado (por convencion o por paths del config)
            $phpPath = "$drive\tools\php\8.2.31"
            $phpCfg = Get-Property $cfg 'php'
            if ($phpCfg) {
                $phpInstall = Get-Property (Get-Property $phpCfg 'paths') 'install'
                if ($phpInstall) {
                    $phpPath = $phpInstall
                }
            }

            # Busqueda automatica si existe una carpeta php en apps
            if (-not (Test-Path (Join-Path $phpPath "php-cgi.exe"))) {
                $foundPhp = Get-ChildItem "$drive\tools" -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like "php*" } | Select-Object -First 1
                if ($foundPhp) {
                    $phpPath = $foundPhp.FullName
                }
            }

            $phpSection = @"

# PHP integration (FastCGI via mod_fcgid)
# Apache Lounge + PHP thread-safe

<IfModule fcgid_module>
    FcgidInitialEnv PHPRC "$phpPath"
    FcgidWrapper "$phpPath\php-cgi.exe" .php
    AddHandler fcgid-script .php
</IfModule>

<FilesMatch "\.php$">
    SetHandler application/x-httpd-php
</FilesMatch>

DirectoryIndex index.html index.php
"@

            $content += "`n`n$phpSection"
        }

        # Escribir sin BOM
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($httpdConf, $content, $utf8NoBom)

        Write-Host "[apache] httpd.conf configured (port $port + basic PHP)." -ForegroundColor Green
    }

    # NO registramos el servicio directamente aqui con NSSM (puede no funcionar bien en todos los entornos).
    # Generamos scripts listos para ejecutar (apuntando a apache-current) para que el usuario
    # los corra como Admin cuando quiera instalar/actualizar el servicio.

    $svcName = Get-Property (Get-Property $cfg 'service') 'name'
    if (-not $svcName) { $svcName = "apache" }
    $displayName = Get-Property (Get-Property $cfg 'service') 'displayName'
    if (-not $displayName) { $displayName = "Apache HTTP Server" }

    $logDir = Get-Property $paths 'logs'
    $stdoutLog = if ($logDir) { Join-Path $logDir "stdout.log" } else { "$drive\logs\apache\stdout.log" }
    $stderrLog = if ($logDir) { Join-Path $logDir "stderr.log" } else { "$drive\logs\apache\stderr.log" }

    # Preferir current symlink
    $serviceDir = $installDir
    if (Test-Path $currentLink) {
        $serviceDir = $currentLink
    }

    # Crear scripts/ dentro de la instalacion (accesible via current)
    $scriptsDir = Join-Path $installDir "scripts"
    New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null

    # Script de setup del servicio (PowerShell). Usa -D FOREGROUND + current + config interna.
    $setupScript = Join-Path $scriptsDir "setup-apache-service.ps1"
    $setupContent = @"
# Auto-generado por deploy.ps1 - $(Get-Date -Format 'yyyy-MM-dd HH:mm')
# Ejecuta como ADMINISTRADOR para registrar el servicio de Apache con NSSM.
# Apunta SIEMPRE a la carpeta current (apache-current) para upgrades.

param(
    [string]`$Nssm = "nssm"
)

`$current   = "$currentLink"
`$exe       = Join-Path `$current "bin\httpd.exe"
`$appDir    = `$current

`$logDir    = "$logDir"
`$stdoutLog = if (`$logDir) { Join-Path `$logDir "stdout.log" } else { Join-Path `$current "logs\stdout.log" }
`$stderrLog = if (`$logDir) { Join-Path `$logDir "stderr.log" } else { Join-Path `$current "logs\stderr.log" }

Write-Host "Configurando servicio NSSM para Apache (current: `$current)..." -ForegroundColor Cyan

& `$Nssm stop $svcName 2>`$null | Out-Null
& `$Nssm remove $svcName confirm 2>`$null | Out-Null

& `$Nssm install $svcName "`$exe" | Out-Null
& `$Nssm set $svcName AppDirectory "`$appDir" | Out-Null
& `$Nssm set $svcName AppParameters "-D FOREGROUND" | Out-Null
& `$Nssm set $svcName DisplayName "$displayName" | Out-Null
& `$Nssm set $svcName Description "Apache HTTP Server $ver" | Out-Null
& `$Nssm set $svcName Start SERVICE_AUTO_START | Out-Null
& `$Nssm set $svcName AppStdout "`$stdoutLog" | Out-Null
& `$Nssm set $svcName AppStderr "`$stderrLog" | Out-Null
& `$Nssm set $svcName AppThrottle 1000 | Out-Null

Write-Host "Listo. Inicia con: nssm start $svcName" -ForegroundColor Green
"@
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($setupScript, $setupContent, $utf8NoBom)

    Write-Host "[apache] Script para instalar servicio creado: $setupScript" -ForegroundColor Green
    Write-Host "        Ejecutalo manualmente como Admin para registrar con NSSM (usa current)." -ForegroundColor DarkGray

    # run.bat simple dentro del apache (para pruebas o apuntar NSSM a el)
    $runBat = Join-Path $installDir "run.bat"
    $runContent = @"
@echo off
cd /d "%~dp0"
echo Iniciando Apache HTTP Server (FOREGROUND) desde %CD%...
bin\httpd.exe -D FOREGROUND
"@
    [System.IO.File]::WriteAllText($runBat, $runContent, $utf8NoBom)

    Write-Host "[apache] Ready: $installDir (port $port) (current -> $currentLink)" -ForegroundColor Green
    Write-Host "[apache] Config: $httpdConf (dentro del apache)" -ForegroundColor Green
    Write-Host "[apache] Para servicio NSSM: ejecuta $scriptsDir\setup-apache-service.ps1 (Admin)" -ForegroundColor DarkGray
}

function Test-ApacheComponent {
    param($cfg, $serverCfg, $downloads)
    $drv = $serverCfg
    $drive = if ($drv -and (Get-Property $drv 'drive')) { Get-Property $drv 'drive' } else { "D:" }

    $ver = Get-Property $cfg 'version'
    if (-not $ver) { $ver = "2.4.68" }

    $paths = Get-Property $cfg 'paths'
    $installP = Get-Property $paths 'install'
    $installDir = if ($installP -and ($installP -match '^[A-Za-z]:')) {
        ([string]$installP).TrimEnd('\','/')
    } elseif ($installP) {
        $clean = $installP.TrimStart('\','/').Replace('/', '\')
        Join-Path "$drive\" $clean
    } else {
        "$drive\tools\apache\$ver"
    }

    $httpd = Join-Path $installDir "bin\httpd.exe"
    $currentLink = Join-Path (Split-Path $installDir -Parent) "apache-current"

    $svcName = Get-Property (Get-Property $cfg 'service') 'name'
    if (Test-Path $httpd) {
        Write-Host "$svcName : installed ($installDir)"
        if (Test-Path $currentLink) {
            Write-Host "  current -> $currentLink" -ForegroundColor DarkGray
        }
        Write-Host "  Para servicio: ejecuta $installDir\scripts\setup-apache-service.ps1 (como Admin)" -ForegroundColor DarkGray
    } else {
        Write-Host "$svcName : NOT INSTALLED"
    }
}

# Helper para debug: imprime la config del servicio NSSM
function Show-ApacheNssmConfig {
    param($svcName = "apache")
    Write-Host "=== NSSM config for $svcName ===" -ForegroundColor Cyan
    Write-Host "Application:   $(nssm get $svcName Application 2>$null)"
    Write-Host "AppDirectory:  $(nssm get $svcName AppDirectory 2>$null)"
    Write-Host "AppParameters: $(nssm get $svcName AppParameters 2>$null)"
    Write-Host "AppStdout:     $(nssm get $svcName AppStdout 2>$null)"
    Write-Host "AppStderr:     $(nssm get $svcName AppStderr 2>$null)"
}

function Uninstall-ApacheComponent {
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
    if (-not $ver) { $ver = "2.4.68" }

    $paths = Get-Property $cfg 'paths'
    function Get-AbsPath([string]$val, [string]$name, [string]$d, [string]$version) {
        $base = if ($d -match '^[A-Za-z]') { ($d -replace '[:\\/]+$', '') + ':' } else { 'D:' }
        if ($val -and ($val -match '^[A-Za-z]:')) { return ([string]$val).TrimEnd('\','/') }
        if (-not $val -or [string]::IsNullOrWhiteSpace($val)) {
            switch ($name) {
                'install' { $val = if ($version) { "tools\apache\$version" } else { 'tools\apache' } }
                'logs'    { $val = 'logs\apache' }
            }
        }
        $clean = $val.TrimStart('\','/').Replace('/', '\')
        return (Join-Path $base $clean)
    }

    $installDir = Get-AbsPath (Get-Property $paths 'install') 'install' $drive $ver
    $logsDir    = Get-AbsPath (Get-Property $paths 'logs')    'logs'    $drive $ver

    $apacheBase   = Split-Path $installDir -Parent
    $currentLink  = Join-Path $apacheBase "apache-current"

    $svcName = Get-Property (Get-Property $cfg 'service') 'name'
    if (-not $svcName) { $svcName = "apache" }

    $nssm = "$drive\tools\nssm\nssm.exe"

    Write-Host "[apache] Uninstalling version $ver..." -ForegroundColor Cyan

    # 1. Stop + remove service
    Stop-And-Remove-Service -ServiceName $svcName -NssmPath $nssm

    # 2. Remove symlink
    if (-not $WhatIf) {
        Remove-SymlinkIfExists -Path $currentLink
    } else {
        Write-Host "[apache] WhatIf: Would remove symlink $currentLink" -ForegroundColor Yellow
    }

    # 3. Remove install dir
    if (Test-Path $installDir) {
        if ($WhatIf) {
            Write-Host "[apache] WhatIf: Would remove $installDir" -ForegroundColor Yellow
        } else {
            $resp = Read-Host "Remove Apache install dir $installDir ? (y/N)"
            if ($Force -or $resp -eq 'y') {
                Remove-Item $installDir -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "[apache] Removed: $installDir" -ForegroundColor Green
            }
        }
    }

    # 4. Logs (optional)
    if ($RemoveLogs -and (Test-Path $logsDir)) {
        if ($WhatIf) {
            Write-Host "[apache] WhatIf: Would remove logs $logsDir" -ForegroundColor Yellow
        } else {
            $resp = Read-Host "Remove logs $logsDir ? (y/N)"
            if ($Force -or $resp -eq 'y') {
                Remove-Item $logsDir -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "[apache] Removed logs: $logsDir" -ForegroundColor Green
            }
        }
    } elseif (Test-Path $logsDir) {
        Write-Host "[apache] Keeping logs: $logsDir" -ForegroundColor DarkGray
    }

    Write-Host "[apache] Uninstall finished." -ForegroundColor Green
}

# Nota: dot-sourced desde deploy.ps1