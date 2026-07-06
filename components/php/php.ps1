# Componente PHP - Thread-safe x64 (para Apache)
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

function Install-PhpComponent {
    param($cfg, $serverCfg, $downloads)

    $drv = $serverCfg
    $drive = if ($drv -and (Get-Property $drv 'drive')) { Get-Property $drv 'drive' } 
             elseif ($drv -and (Get-Property $drv 'appDrive')) { Get-Property $drv 'appDrive' } 
             else { "D:" }

    $ver = Get-Property $cfg 'version'
    if (-not $ver) { $ver = "8.2.31" }

    $base = $null
    if ($downloads) { $base = Get-Property $downloads 'base' }
    if (-not $base) { $base = "https://dalthonmh.com/bin" }

    $url = Get-Property $cfg 'url'
    if (-not $url) {
        $url = "$base/php-$ver-x64.zip"
    }

    # Obtener paths
    $paths = Get-Property $cfg 'paths'
    function Get-AbsPath([string]$val, [string]$name, [string]$d, [string]$version) {
        $base = if ($d -match '^[A-Za-z]') { ($d -replace '[:\\/]+$', '') + ':' } else { 'D:' }
        if ($val -and ($val -match '^[A-Za-z]:')) { return ([string]$val).TrimEnd('\','/') }
        if (-not $val -or [string]::IsNullOrWhiteSpace($val)) {
            switch ($name) {
                'install' { $val = if ($version) { "tools\php\$version" } else { 'tools\php' } }
            }
        }
        $clean = $val.TrimStart('\','/').Replace('/', '\')
        return (Join-Path $base $clean)
    }

    $installP = Get-Property $paths 'install'
    $paths = @{
        install = Get-AbsPath $installP 'install' $drive $ver
    }

    $cache = "$drive\downloads\cache"
    New-Item -ItemType Directory -Path $cache, (Get-Property $paths 'install') -Force | Out-Null

    $exe = Join-Path (Get-Property $paths 'install') "php.exe"

    # 1. Descargar usando caché compartida (solo una vez por versión)
    $zip = Get-CachedDownload -Url $url -CacheDir $cache -FileName "php-$ver-x64.zip" -Label "[php]"

    # 2. Extraer solo si no existe
    if (-not (Test-Path $exe)) {
        Write-Host "[php] Extracting version $ver..." -ForegroundColor Cyan
        $installPath = Get-Property $paths 'install'

        # Limpiar residual si existe
        Get-ChildItem $installPath -Directory -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

        try {
            Expand-Archive -Path $zip -DestinationPath $installPath -Force

            # El zip de PHP suele estar plano o con subcarpeta, movemos si hace falta
            $sub = Get-ChildItem $installPath -Directory | Where-Object { $_.Name -like "php*" } | Select-Object -First 1
            if ($sub) {
                Get-ChildItem $sub.FullName | Move-Item -Destination $installPath -Force
                Remove-Item $sub.FullName -Recurse -Force
            }
        } catch {
            Write-Host "[php] Extract failed (bad or corrupted zip). Removing from cache." -ForegroundColor Red
            Remove-Item $zip -Force -ErrorAction SilentlyContinue
            throw
        }
    }

    # 3. Configuracion inicial de php.ini (basica, el usuario la actualizara)
    $phpIniProd = Join-Path (Get-Property $paths 'install') "php.ini-production"
    $phpIni     = Join-Path (Get-Property $paths 'install') "php.ini"

    if (-not (Test-Path $phpIni) -and (Test-Path $phpIniProd)) {
        Copy-Item $phpIniProd $phpIni -Force

        $content = Get-Content $phpIni -Raw

        # Config basica inicial
        $content = $content -replace '^(;?)extension_dir\s*=.*', 'extension_dir = "ext"'
        $content = $content -replace '^(;?)date\.timezone\s*=.*', 'date.timezone = "UTC"'
        $content = $content -replace '^(;?)cgi\.force_redirect\s*=.*', 'cgi.force_redirect = 0'
        $content = $content -replace '^(;?)cgi\.fix_pathinfo\s*=.*', 'cgi.fix_pathinfo = 1'
        $content = $content -replace '^(;?)error_reporting\s*=.*', 'error_reporting = E_ALL'
        $content = $content -replace '^(;?)display_errors\s*=.*', 'display_errors = On'
        $content = $content -replace '^(;?)log_errors\s*=.*', 'log_errors = On'
        $content = $content -replace '^(;?)variables_order\s*=.*', 'variables_order = "GPCS"'

        # Escribir sin BOM
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($phpIni, $content, $utf8NoBom)

        Write-Host "[php] Initial php.ini created (based on php.ini-production)." -ForegroundColor Green
    }

    Write-Host "[php] Ready: $(Get-Property $paths 'install')" -ForegroundColor Green

    # Agregar PHP al PATH (necesario para que composer y otras herramientas funcionen)
    Ensure-PhpInPath -phpDir (Get-Property $paths 'install')
}

# Asegurarnos de que la función esté disponible aunque se llame desde otro componente
if (-not (Get-Command Ensure-PhpInPath -ErrorAction SilentlyContinue)) {
    function Ensure-PhpInPath {
        param($phpDir)
        try {
            $currentPath = [Environment]::GetEnvironmentVariable("Path", "Machine")
            if ($currentPath -notlike "*$phpDir*") {
                $newPath = ($currentPath.TrimEnd(';') + ";$phpDir").TrimStart(';')
                [Environment]::SetEnvironmentVariable("Path", $newPath, "Machine")
                $env:Path = ($env:Path.TrimEnd(';') + ";$phpDir").TrimStart(';')
            }
        } catch {}
    }
}

function Ensure-PhpInPath {
    param($phpDir)
    try {
        $currentPath = [Environment]::GetEnvironmentVariable("Path", "Machine")
        if ($currentPath -notlike "*$phpDir*") {
            $newPath = ($currentPath.TrimEnd(';') + ";$phpDir").TrimStart(';')
            [Environment]::SetEnvironmentVariable("Path", $newPath, "Machine")
            $env:Path = ($env:Path.TrimEnd(';') + ";$phpDir").TrimStart(';')
            Write-Host "[php] Added to system PATH." -ForegroundColor Green
        }
    } catch {
        Write-Host "[php] Could not modify global PATH (run as Administrator if needed)." -ForegroundColor Yellow
    }
}

function Test-PhpComponent {
    param($cfg, $serverCfg, $downloads)
    $drv = $serverCfg
    $drive = if ($drv -and (Get-Property $drv 'drive')) { Get-Property $drv 'drive' } else { "D:" }

    $installP = Get-Property (Get-Property $cfg 'paths') 'install'
    if (-not $installP) { $installP = "apps\php" }
    $php = Join-Path "$drive\" $installP
    $phpExe = Join-Path $php "php.exe"

    if (Test-Path $phpExe) {
        Write-Host "PHP : installed ($php)"
    } else {
        Write-Host "PHP : NOT INSTALLED"
    }
}

function Uninstall-PhpComponent {
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
    if (-not $ver) { $ver = "8.2.31" }

    $paths = Get-Property $cfg 'paths'
    function Get-AbsPath([string]$val, [string]$name, [string]$d, [string]$version) {
        $base = if ($d -match '^[A-Za-z]') { ($d -replace '[:\\/]+$', '') + ':' } else { 'D:' }
        if ($val -and ($val -match '^[A-Za-z]:')) { return ([string]$val).TrimEnd('\','/') }
        if (-not $val -or [string]::IsNullOrWhiteSpace($val)) {
            switch ($name) {
                'install' { $val = if ($version) { "tools\php\$version" } else { 'tools\php' } }
            }
        }
        $clean = $val.TrimStart('\','/').Replace('/', '\')
        return (Join-Path $base $clean)
    }

    $installDir = Get-AbsPath (Get-Property $paths 'install') 'install' $drive $ver

    Write-Host "[php] Uninstalling PHP $ver..." -ForegroundColor Cyan

    # 1. Remove from PATH
    if (-not $WhatIf) {
        Remove-FromSystemPath -PathToRemove $installDir
    } else {
        Write-Host "[php] WhatIf: Would remove PHP from PATH: $installDir" -ForegroundColor Yellow
    }

    # 2. Remove install directory
    if (Test-Path $installDir) {
        if ($WhatIf) {
            Write-Host "[php] WhatIf: Would remove $installDir" -ForegroundColor Yellow
        } else {
            $resp = Read-Host "Remove PHP install dir $installDir ? (y/N)"
            if ($Force -or $resp -eq 'y') {
                Remove-Item $installDir -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "[php] Removed: $installDir" -ForegroundColor Green
            }
        }
    }

    # Note: We do NOT remove php.ini or user data unless user deletes the folder manually.

    Write-Host "[php] Uninstall finished for PHP." -ForegroundColor Green
}

# Nota: dot-sourced desde deploy.ps1