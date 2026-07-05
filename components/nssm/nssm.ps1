# Componente NSSM
# Se puede habilitar por separado de nginx u otros servicios.

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

function Install-NssmComponent {
    param($cfg, $serverCfg, $downloads)

    $drv = $serverCfg
    $drive = if ($drv -and (Get-Property $drv 'drive')) { Get-Property $drv 'drive' } 
             elseif ($drv -and (Get-Property $drv 'appDrive')) { Get-Property $drv 'appDrive' } 
             else { "D:" }

    $ver = Get-Property $cfg 'version'
    if (-not $ver) { $ver = "2.24" }

    $base = $null
    if ($downloads) { $base = Get-Property $downloads 'base' }
    if (-not $base) { $base = "https://dalthonmh.com/bin" }

    $url = Get-Property $cfg 'url'
    if (-not $url) {
        $url = "$base/nssm-$ver.zip"
    }

    $paths = Get-Property $cfg 'paths'
    $nssmDir = if ($paths -and (Get-Property $paths 'install')) {
        Get-Property $paths 'install'
    } else {
        "$drive\tools\nssm"
    }
    $nssm = Join-Path $nssmDir "nssm.exe"
    $cache = "$drive\downloads\cache"

    if (Test-Path $nssm) {
        Write-Host "[nssm] Already installed at $nssmDir" -ForegroundColor DarkGray
        Ensure-NssmInPath -nssmDir $nssmDir
        return
    }

    Write-Host "[nssm] Installing NSSM v$ver..." -ForegroundColor Cyan

    New-Item -ItemType Directory -Path $cache, $nssmDir -Force | Out-Null

    $zip = Get-CachedDownload -Url $url -CacheDir $cache -FileName "nssm-$ver.zip" -Label "[nssm]"

    try {
        Expand-Archive $zip $cache -Force
        $found = Get-ChildItem $cache -Recurse -Filter nssm.exe | Select-Object -First 1
        if ($found) {
            Copy-Item $found.FullName $nssm -Force
        } else {
            throw "[nssm] nssm.exe not found inside the zip"
        }
    } catch {
        Write-Host "[nssm] Extract failed (bad or corrupted zip). Removing from cache." -ForegroundColor Red
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        throw
    }

    Ensure-NssmInPath -nssmDir $nssmDir
    Write-Host "[nssm] Installed successfully at $nssm" -ForegroundColor Green
}

function Ensure-NssmInPath {
    param($nssmDir)
    try {
        $currentPath = [Environment]::GetEnvironmentVariable("Path", "Machine")
        if ($currentPath -notlike "*$nssmDir*") {
            $newPath = ($currentPath.TrimEnd(';') + ";$nssmDir").TrimStart(';')
            [Environment]::SetEnvironmentVariable("Path", $newPath, "Machine")
            $env:Path = ($env:Path.TrimEnd(';') + ";$nssmDir").TrimStart(';')
            Write-Host "[nssm] Added to system PATH." -ForegroundColor Green
        }
    } catch {
        Write-Host "[nssm] Could not modify global PATH (run as Administrator if needed)." -ForegroundColor Yellow
    }
}

function Test-NssmComponent {
    param($cfg, $serverCfg, $downloads)
    $drv = $serverCfg
    $drive = if ($drv -and (Get-Property $drv 'drive')) { Get-Property $drv 'drive' } else { "D:" }

    $paths = Get-Property $cfg 'paths'
    $nssmDir = if ($paths -and (Get-Property $paths 'install')) {
        Get-Property $paths 'install'
    } else {
        "$drive\tools\nssm"
    }
    $nssm = Join-Path $nssmDir "nssm.exe"

    if (Test-Path $nssm) {
        Write-Host "NSSM : installed ($nssm)"
    } else {
        Write-Host "NSSM : NOT INSTALLED"
    }
}

# Note: dot-sourced from deploy.ps1