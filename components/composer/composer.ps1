# Componente Composer
# Instalación automática (sin GUI). Usa composer.phar + wrapper .bat
# Se puede habilitar independientemente.

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

function Install-ComposerComponent {
    param($cfg, $serverCfg, $downloads)

    $drv = $serverCfg
    $drive = if ($drv -and (Get-Property $drv 'drive')) { Get-Property $drv 'drive' } 
             elseif ($drv -and (Get-Property $drv 'appDrive')) { Get-Property $drv 'appDrive' } 
             else { "D:" }

    $base = $null
    if ($downloads) { $base = Get-Property $downloads 'base' }
    if (-not $base) { $base = "https://dalthonmh.com/bin" }

    $url = Get-Property $cfg 'url'
    $ver = Get-Property $cfg 'version'

    if (-not $url) {
        if ($ver) {
            # Soporta el formato que subiste: composer-2.10.2.phar.zip
            $url = "$base/composer-$ver.phar.zip"
        } else {
            $url = "$base/composer.phar"
        }
    }

    $paths = Get-Property $cfg 'paths'
    $installP = if ($paths) { Get-Property $paths 'install' } else { $null }
    if (-not $installP) { $installP = "tools\composer" }

    $composerDir = if ($installP -match '^[A-Za-z]:') { $installP } else { Join-Path "$drive\" $installP.TrimStart('\','/') }

    $cache = "$drive\downloads\cache"
    New-Item -ItemType Directory -Path $cache, $composerDir -Force | Out-Null

    $phar = Join-Path $composerDir "composer.phar"
    $bat  = Join-Path $composerDir "composer.bat"

    $isZip = $url -like "*.zip"

    if ($isZip) {
        $zipFileName = if ($ver) { "composer-$ver.phar.zip" } else { "composer.phar.zip" }
        $downloadFile = Get-CachedDownload -Url $url -CacheDir $cache -FileName $zipFileName -Label "[composer]"
    } else {
        # Direct .phar: download to cache, then ensure it's in target
        $cachedPhar = Get-CachedDownload -Url $url -CacheDir $cache -FileName "composer.phar" -Label "[composer]"
        if (-not (Test-Path $phar)) {
            Copy-Item $cachedPhar $phar -Force
        }
        $downloadFile = $cachedPhar
    }

    # Extraer solo si el .phar final no existe (para zips)
    if ($isZip -and -not (Test-Path $phar)) {
        Write-Host "[composer] Extracting..." -ForegroundColor Cyan
        Expand-Archive -Path $downloadFile -DestinationPath $cache -Force

        $foundPhar = Get-ChildItem $cache -Recurse -Filter "*.phar" | Select-Object -First 1
        if ($foundPhar) {
            Copy-Item $foundPhar.FullName $phar -Force
        } else {
            throw "[composer] No se encontró ningún archivo .phar dentro del zip"
        }

        # NO borrar el zip de caché. Solo limpiar carpeta temporal si es distinta.
        $extractDir = $foundPhar.Directory.FullName
        if ($extractDir -ne $cache -and $extractDir -ne $composerDir) {
            Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Crear wrapper .bat si no existe
    if (-not (Test-Path $bat)) {
        $batContent = "@echo off`r`nphp `"%~dp0composer.phar`" %*"
        [System.IO.File]::WriteAllText($bat, $batContent, [System.Text.Encoding]::ASCII)
        Write-Host "[composer] Created composer.bat wrapper." -ForegroundColor Green
    }

    # Asegurar que PHP esté en PATH (por si el componente php se ejecutó antes)
    $phpDir = "$drive\apps\php\8.2.31"
    if (Test-Path (Join-Path $phpDir "php.exe")) {
        try {
            $current = [Environment]::GetEnvironmentVariable("Path", "Machine")
            if ($current -notlike "*$phpDir*") {
                $new = ($current.TrimEnd(';') + ";$phpDir").TrimStart(';')
                [Environment]::SetEnvironmentVariable("Path", $new, "Machine")
                $env:Path = ($env:Path.TrimEnd(';') + ";$phpDir").TrimStart(';')
            }
        } catch {}
    }

    # Agregar al PATH del sistema (igual que nssm)
    Ensure-ComposerInPath -composerDir $composerDir

    Write-Host "[composer] Ready: $composerDir" -ForegroundColor Green
}

function Ensure-ComposerInPath {
    param($composerDir)
    try {
        $currentPath = [Environment]::GetEnvironmentVariable("Path", "Machine")
        if ($currentPath -notlike "*$composerDir*") {
            $newPath = ($currentPath.TrimEnd(';') + ";$composerDir").TrimStart(';')
            [Environment]::SetEnvironmentVariable("Path", $newPath, "Machine")
            $env:Path = ($env:Path.TrimEnd(';') + ";$composerDir").TrimStart(';')
            Write-Host "[composer] Added to system PATH." -ForegroundColor Green
        }
    } catch {
        Write-Host "[composer] Could not modify global PATH (run as Administrator if needed)." -ForegroundColor Yellow
    }
}

function Test-ComposerComponent {
    param($cfg, $serverCfg, $downloads)
    $drv = $serverCfg
    $drive = if ($drv -and (Get-Property $drv 'drive')) { Get-Property $drv 'drive' } else { "D:" }

    $installP = Get-Property (Get-Property $cfg 'paths') 'install'
    if (-not $installP) { $installP = "apps\composer" }
    $composerDir = if ($installP -match '^[A-Za-z]:') { $installP } else { Join-Path "$drive\" $installP.TrimStart('\','/') }

    $bat = Join-Path $composerDir "composer.bat"
    if (Test-Path $bat) {
        Write-Host "Composer : installed ($composerDir)"
    } else {
        Write-Host "Composer : NOT INSTALLED"
    }
}

function Uninstall-ComposerComponent {
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

    $paths = Get-Property $cfg 'paths'
    $installP = if ($paths) { Get-Property $paths 'install' } else { $null }
    if (-not $installP) { $installP = "tools\composer" }

    $composerDir = if ($installP -match '^[A-Za-z]:') { $installP } else { Join-Path "$drive\" ($installP.TrimStart('\','/')) }

    Write-Host "[composer] Uninstalling Composer..." -ForegroundColor Cyan

    if (-not $WhatIf) {
        Remove-FromSystemPath -PathToRemove $composerDir
    } else {
        Write-Host "[composer] WhatIf: Would remove from PATH: $composerDir" -ForegroundColor Yellow
    }

    if (Test-Path $composerDir) {
        if ($WhatIf) {
            Write-Host "[composer] WhatIf: Would remove $composerDir" -ForegroundColor Yellow
        } else {
            $resp = Read-Host "Remove Composer directory $composerDir ? (y/N)"
            if ($Force -or $resp -eq 'y') {
                Remove-Item $composerDir -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "[composer] Removed: $composerDir" -ForegroundColor Green
            }
        }
    }

    Write-Host "[composer] Uninstall finished." -ForegroundColor Green
}

# Nota: dot-sourced desde deploy.ps1, no es necesario Export-ModuleMember