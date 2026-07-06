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

    # 3. Configurar httpd.conf (puerto + PHP basico)
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

    # 4. Servicio con NSSM (si esta disponible)
    $svcName = Get-Property (Get-Property $cfg 'service') 'name'
    $useNssm = (Get-Property (Get-Property $cfg 'service') 'useNssm')
    $nssm = "$drive\tools\nssm\nssm.exe"

    if ((Test-Path $nssm) -and ($useNssm -ne $false)) {
        $existingSvc = Get-Service $svcName -ErrorAction SilentlyContinue
        $currentApp = $null
        if ($existingSvc) {
            $currentApp = & {
                $ErrorActionPreference = 'SilentlyContinue'
                & $nssm get $svcName Application 2>&1
            }
        }

        if ($currentApp -ne $httpdExe) {
            & {
                $ErrorActionPreference = 'SilentlyContinue'
                & $nssm stop $svcName 2>&1 | Out-Null
                & $nssm remove $svcName confirm 2>&1 | Out-Null
                & $nssm install $svcName $httpdExe | Out-Null
                & $nssm set $svcName AppDirectory (Join-Path $installDir "bin") | Out-Null
                & $nssm set $svcName AppParameters "-f `"$httpdConf`"" | Out-Null
                & $nssm set $svcName DisplayName (Get-Property (Get-Property $cfg 'service') 'displayName') | Out-Null
                & $nssm set $svcName Start SERVICE_AUTO_START | Out-Null
                & $nssm set $svcName AppStdout "$drive\logs\apache\stdout.log" | Out-Null
                & $nssm set $svcName AppStderr "$drive\logs\apache\stderr.log" | Out-Null
                & $nssm set $svcName AppThrottle 1000 | Out-Null
            }
            Write-Host "[apache] Service configured with NSSM." -ForegroundColor Green
        }
    } else {
        # Fallback basico
        $existing = Get-Service $svcName -ErrorAction SilentlyContinue
        if (-not $existing) {
            New-Service -Name $svcName `
                        -BinaryPathName "`"$httpdExe`" -f `"$httpdConf`"" `
                        -DisplayName (Get-Property (Get-Property $cfg 'service') 'displayName') `
                        -StartupType Automatic | Out-Null
            Write-Host "[apache] Service registered (basic)." -ForegroundColor Yellow
        }
    }

    # Iniciar servicio si esta parado
    $svc = Get-Service $svcName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Running') {
        Start-Service $svcName -ErrorAction SilentlyContinue
    }

    Write-Host "[apache] Ready: $installDir (port $port)" -ForegroundColor Green
}

function Test-ApacheComponent {
    param($cfg, $serverCfg, $downloads)
    $drv = $serverCfg
    $drive = if ($drv -and (Get-Property $drv 'drive')) { Get-Property $drv 'drive' } else { "D:" }

    $installP = Get-Property (Get-Property $cfg 'paths') 'install'
    if (-not $installP) { $installP = "apps\apache" }
    $apache = Join-Path "$drive\" $installP
    $httpd = Join-Path $apache "bin\httpd.exe"

    $svcName = Get-Property (Get-Property $cfg 'service') 'name'
    if (Test-Path $httpd) {
        Write-Host "$svcName : installed ($apache)"
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