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
                'install' { $val = if ($version) { "apps\apache\$version" } else { 'apps\apache' } }
                'config'  { $val = 'config\apache' }
                'data'    { $val = 'data\apache' }
                'logs'    { $val = 'logs\apache' }
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

    $installDir = Get-Property $paths 'install'
    $dirsToCreate = @(
        $cache,
        $installDir,
        (Get-Property $paths 'config'),
        (Get-Property $paths 'data'),
        (Get-Property $paths 'logs')
    )
    New-Item -ItemType Directory -Path $dirsToCreate -Force | Out-Null

    # Crear htdocs basico
    $htdocs = Join-Path (Get-Property $paths 'data') "htdocs"
    New-Item -ItemType Directory -Path $htdocs -Force | Out-Null
    $indexHtml = Join-Path $htdocs "index.html"
    if (-not (Test-Path $indexHtml)) {
        '<h1>It works! (Apache on port {{port}})</h1>' -replace '{{port}}', $port | Out-File $indexHtml -Encoding utf8
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

        Expand-Archive -Path $zip -DestinationPath $installDir -Force

        # Mover contenido si el zip crea subcarpeta (ej Apache24 o httpd-2.4.68)
        $sub = Get-ChildItem $installDir -Directory | Where-Object { 
            $_.Name -like "*apache*" -or $_.Name -like "*httpd*" -or $_.Name -like "Apache*" 
        } | Select-Object -First 1

        if ($sub) {
            Get-ChildItem $sub.FullName | Move-Item -Destination $installDir -Force
            Remove-Item $sub.FullName -Recurse -Force
        }
    }

    # 3. Configurar httpd.conf (puerto + PHP basico)
    $httpdConf = Join-Path $installDir "conf\httpd.conf"
    if (Test-Path $httpdConf) {
        $content = Get-Content $httpdConf -Raw

        # Cambiar Listen al puerto deseado
        $content = $content -replace '(?m)^Listen\s+.*$', "Listen $port"

        # Agregar configuracion de PHP si no existe todavia
        if ($content -notmatch 'php-cgi') {
            # Intentar detectar php instalado (por convencion o por paths del config)
            $phpPath = "$drive\apps\php\8.2.31"
            $phpCfg = Get-Property $cfg 'php'
            if ($phpCfg) {
                $phpInstall = Get-Property (Get-Property $phpCfg 'paths') 'install'
                if ($phpInstall) {
                    $phpPath = $phpInstall
                }
            }

            # Busqueda automatica si existe una carpeta php en apps
            if (-not (Test-Path (Join-Path $phpPath "php-cgi.exe"))) {
                $foundPhp = Get-ChildItem "$drive\apps" -Directory -ErrorAction SilentlyContinue |
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
    $nssm = "$drive\apps\nssm\nssm.exe"

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

    if (Test-Path $httpd) {
        Write-Host "Apache : installed ($apache)"
    } else {
        Write-Host "Apache : NOT INSTALLED"
    }
}

# Nota: dot-sourced desde deploy.ps1