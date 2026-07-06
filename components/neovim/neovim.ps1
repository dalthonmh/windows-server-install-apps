# Componente Neovim
# Recomendado sobre Vim clásico / GVim.
# Usa el zip portable oficial (nvim-win64.zip).
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

function Install-NeovimComponent {
    param($cfg, $serverCfg, $downloads)

    $drv = $serverCfg
    $drive = if ($drv -and (Get-Property $drv 'drive')) { Get-Property $drv 'drive' } 
             elseif ($drv -and (Get-Property $drv 'appDrive')) { Get-Property $drv 'appDrive' } 
             else { "D:" }

    $ver = Get-Property $cfg 'version'
    if (-not $ver) { $ver = $null }

    $base = $null
    if ($downloads) { $base = Get-Property $downloads 'base' }
    if (-not $base) { $base = "https://dalthonmh.com/bin" }

    $url = Get-Property $cfg 'url'
    if (-not $url) {
        if ($ver) {
            $url = "$base/nvim-win64-$ver.zip"
        } else {
            $url = "$base/nvim-win64.zip"
        }
    }

    $paths = Get-Property $cfg 'paths'
    function Get-AbsPath([string]$val, [string]$name, [string]$d, [string]$version) {
        $base = if ($d -match '^[A-Za-z]') { ($d -replace '[:\\/]+$', '') + ':' } else { 'D:' }
        if ($val -and ($val -match '^[A-Za-z]:')) { return ([string]$val).TrimEnd('\','/') }
        if (-not $val -or [string]::IsNullOrWhiteSpace($val)) {
            switch ($name) {
                'install' { $val = if ($version) { "tools\neovim\$version" } else { 'tools\neovim' } }
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
    $installDir = Get-Property $paths 'install'

    New-Item -ItemType Directory -Path $cache, $installDir -Force | Out-Null

    $nvimExe = Join-Path $installDir "bin\nvim.exe"

    # 1. Descargar usando caché compartida (solo una vez por versión)
    $zipName = if ($ver) { "nvim-win64-$ver.zip" } else { "nvim-win64.zip" }
    $zip = Get-CachedDownload -Url $url -CacheDir $cache -FileName $zipName -Label "[neovim]"

    # 2. Extraer solo si no existe el ejecutable
    if (-not (Test-Path $nvimExe)) {
        Write-Host "[neovim] Extracting version $ver..." -ForegroundColor Cyan

        # Limpiar cualquier subcarpeta nvim residual
        Get-ChildItem $installDir -Directory -Force | Where-Object { $_.Name -like "nvim*" } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

        try {
            Expand-Archive -Path $zip -DestinationPath $installDir -Force

            # El zip oficial suele tener estructura doble: nvim-win64\nvim-win64\...
            # Aplanamos hasta que no queden subcarpetas nvim-*
            while ($true) {
                $sub = Get-ChildItem $installDir -Directory | Where-Object { $_.Name -like "nvim*" } | Select-Object -First 1
                if ($sub) {
                    Get-ChildItem $sub.FullName | Move-Item -Destination $installDir -Force
                    Remove-Item $sub.FullName -Recurse -Force
                } else {
                    break
                }
            }
        } catch {
            Write-Host "[neovim] Extract failed (bad or corrupted zip). Removing from cache." -ForegroundColor Red
            Remove-Item $zip -Force -ErrorAction SilentlyContinue
            throw
        }
    }

    # 3. Agregar bin al PATH del sistema
    $binDir = Join-Path $installDir "bin"
    Ensure-NeovimInPath -binDir $binDir

    Write-Host "[neovim] Ready: $installDir" -ForegroundColor Green
}

function Ensure-NeovimInPath {
    param($binDir)
    try {
        $currentMachine = [Environment]::GetEnvironmentVariable("Path", "Machine")
        $currentEnv = $env:Path

        # Always ensure in current session
        if ($currentEnv -notlike "*$binDir*") {
            $env:Path = ($currentEnv.TrimEnd(';') + ";$binDir").TrimStart(';')
        }

        # Add to Machine if not present
        if ($currentMachine -notlike "*$binDir*") {
            $newPath = ($currentMachine.TrimEnd(';') + ";$binDir").TrimStart(';')
            [Environment]::SetEnvironmentVariable("Path", $newPath, "Machine")
            Write-Host "[neovim] Added to system PATH." -ForegroundColor Green
        }
    } catch {
        Write-Host "[neovim] Could not modify global PATH (run as Administrator if needed)." -ForegroundColor Yellow
    }
}

function Test-NeovimComponent {
    param($cfg, $serverCfg, $downloads)
    $drv = $serverCfg
    $drive = if ($drv -and (Get-Property $drv 'drive')) { Get-Property $drv 'drive' } else { "D:" }

    $installP = Get-Property (Get-Property $cfg 'paths') 'install'
    if (-not $installP) { $installP = "apps\neovim" }
    $installDir = if ($installP -match '^[A-Za-z]:') { $installP } else { Join-Path "$drive\" $installP.TrimStart('\','/') }

    $nvimExe = Join-Path $installDir "bin\nvim.exe"
    if (Test-Path $nvimExe) {
        Write-Host "Neovim : installed ($installDir)"
    } else {
        Write-Host "Neovim : NOT INSTALLED"
    }
}

function Uninstall-NeovimComponent {
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
    if (-not $installP) { $installP = "tools\neovim" }

    $installDir = if ($installP -match '^[A-Za-z]:') { $installP } else { Join-Path "$drive\" ($installP.TrimStart('\','/')) }

    Write-Host "[neovim] Uninstalling Neovim..." -ForegroundColor Cyan

    if (-not $WhatIf) {
        Remove-FromSystemPath -PathToRemove $installDir
    } else {
        Write-Host "[neovim] WhatIf: Would remove from PATH: $installDir" -ForegroundColor Yellow
    }

    if (Test-Path $installDir) {
        if ($WhatIf) {
            Write-Host "[neovim] WhatIf: Would remove $installDir" -ForegroundColor Yellow
        } else {
            $resp = Read-Host "Remove Neovim directory $installDir ? (y/N)"
            if ($Force -or $resp -eq 'y') {
                Remove-Item $installDir -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "[neovim] Removed: $installDir" -ForegroundColor Green
            }
        }
    }

    Write-Host "[neovim] Uninstall finished." -ForegroundColor Green
}

# Nota: Se usa dot-sourcing desde deploy.ps1
