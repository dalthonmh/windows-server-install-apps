<#
.SYNOPSIS
    Desinstalador para los componentes instalados por deploy.ps1.
    Seguro por defecto: NO borra config, logs ni data a menos que se indique explícitamente.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ConfigPath = "config.psd1",

    # Componentes específicos a desinstalar. Ej: -Component nginx,php
    [string[]]$Component,

    # Desinstala todo lo que esté habilitado en config
    [switch]$All,

    # No pide confirmación
    [switch]$Force,

    # Solo muestra lo que haría (dry-run)
    [switch]$WhatIf,

    # Borra también la configuración persistente (¡peligroso!)
    [switch]$RemoveConfig,

    # Borra logs
    [switch]$RemoveLogs,

    # Borra data (si aplica)
    [switch]$RemoveData,

    # Borra la carpeta de descargas cacheadas
    [switch]$RemoveCache,

    # Borra los symlinks current (por defecto sí)
    [switch]$KeepSymlinks
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ConfigPath)) {
    throw "Configuration file not found: $ConfigPath"
}

# Load shared uninstall helpers
. (Join-Path $PSScriptRoot "lib\Uninstall-Helpers.ps1")

function Get-TopLevelKeys($obj) {
    if ($null -eq $obj) { return @() }
    if ($obj -is [string]) { return @() }
    if ($obj -is [hashtable]) { return @($obj.Keys) }
    if ($obj -is [System.Collections.IDictionary]) { return @($obj.Keys) }
    if ($obj -is [psobject]) {
        return @($obj.PSObject.Properties | ForEach-Object { $_.Name })
    }
    return @()
}

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

function Test-IsEnabled($value) {
    return $value -eq $true -or $value -eq 'true' -or $value -eq 1
}

function Read-Config([string]$path) {
    if (-not (Test-Path $path)) { throw "File does not exist: $path" }
    $ext = [System.IO.Path]::GetExtension($path).ToLower()
    if ($ext -eq '.psd1') {
        return Import-PowerShellDataFile -Path $path -ErrorAction Stop
    }
    throw "Only .psd1 format is supported."
}

function Log($msg, $color = "White") {
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts] $msg" -ForegroundColor $color
}

function Confirm-Action {
    param([string]$Message)
    if ($Force -or $WhatIf) { return $true }
    $response = Read-Host "$Message (y/N)"
    return $response -match '^[yY]'
}

# === Main ===

$config = Read-Config $ConfigPath

$drv = Get-Property $config 'server'
$drive = if ($drv -and (Get-Property $drv 'drive')) { Get-Property $drv 'drive' } 
         elseif ($drv -and (Get-Property $drv 'appDrive')) { Get-Property $drv 'appDrive' } 
         else { "D:" }

$serverName = Get-Property $drv 'name'
if (-not $serverName) { $serverName = "(sin nombre)" }

Write-Host "=== Uninstalling on $serverName (drive: $drive) ===" -ForegroundColor Cyan

$searchSpace = $config
$compSection = Get-Property $config 'components'
if ($compSection) { $searchSpace = $compSection }

$searchKeys = Get-TopLevelKeys $searchSpace

$componentsToProcess = @()

if ($Component -and $Component.Count -gt 0) {
    $componentsToProcess = $Component
} else {
    foreach ($key in $searchKeys) {
        if ($key -eq 'server') { continue }
        $comp = Get-Property $searchSpace $key
        $enabled = Get-Property $comp 'enabled'
        if ($comp -and (Test-IsEnabled $enabled)) {
            $componentsToProcess += $key
        }
    }
}

if ($componentsToProcess.Count -eq 0) {
    Write-Host "No components to uninstall." -ForegroundColor Yellow
    exit 0
}

Write-Host "Components to uninstall: $($componentsToProcess -join ', ')" -ForegroundColor Yellow

if (-not $Force -and -not $WhatIf) {
    Write-Host ""
    Write-Host "WARNING: This will stop services and remove installed software." -ForegroundColor Red
    Write-Host "By default, config/, logs/ and data/ folders are KEPT." -ForegroundColor Yellow
    if (-not (Confirm-Action "Continue?")) {
        Write-Host "Aborted." -ForegroundColor Yellow
        exit 0
    }
}

$downloads = Get-Property $config 'downloads'
$nssmPath = "$drive\tools\nssm\nssm.exe"
if (-not (Test-Path $nssmPath)) { $nssmPath = $null }

foreach ($name in $componentsToProcess) {
    $compCfg = Get-Property $searchSpace $name
    $compScript = Join-Path "components" "$name\$name.ps1"

    if (-not (Test-Path $compScript)) {
        Write-Host "[uninstall] No uninstall logic for '$name' (script not found)." -ForegroundColor Yellow
        continue
    }

    Write-Host ""
    Write-Host ">>> Processing uninstall for: $name" -ForegroundColor Cyan

    . $compScript

    $funcName = "Uninstall-" + $name.Substring(0,1).ToUpper() + $name.Substring(1) + "Component"

    if (Get-Command $funcName -ErrorAction SilentlyContinue) {
        & $funcName -cfg $compCfg -serverCfg $drv -downloads $downloads -WhatIf:$WhatIf -Force:$Force `
                    -RemoveConfig:$RemoveConfig -RemoveLogs:$RemoveLogs -RemoveData:$RemoveData
    } else {
        Write-Host "[uninstall] No $funcName function found in $compScript. Doing basic cleanup..." -ForegroundColor Yellow

        # Basic fallback cleanup (best effort)
        $installP = Get-Property (Get-Property $compCfg 'paths') 'install'
        if ($installP) {
            $full = if ($installP -match '^[A-Za-z]:') { $installP } else { Join-Path "$drive\" ($installP.TrimStart('\','/')) }
            if (Test-Path $full) {
                if ($WhatIf) {
                    Write-Host "[uninstall] WhatIf: Would remove $full" -ForegroundColor Yellow
                } elseif (Confirm-Action "Remove directory $full ?") {
                    Remove-Item $full -Recurse -Force -ErrorAction SilentlyContinue
                    Write-Host "[uninstall] Removed: $full" -ForegroundColor Green
                }
            }
        }
    }
}

# Global cleanup
if ($RemoveCache) {
    $cache = "$drive\downloads\cache"
    if (Test-Path $cache) {
        if ($WhatIf) {
            Write-Host "[uninstall] WhatIf: Would remove cache $cache" -ForegroundColor Yellow
        } elseif (Confirm-Action "Remove download cache $cache ?") {
            Remove-Item $cache -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "[uninstall] Removed cache." -ForegroundColor Green
        }
    }
}

Write-Host ""
if ($WhatIf) {
    Write-Host "WhatIf completed. No changes were made." -ForegroundColor Yellow
} else {
    Write-Host "Uninstall finished." -ForegroundColor Green
    Write-Host "Tip: You may need to restart the server or open a new terminal for PATH changes to fully apply." -ForegroundColor DarkGray
}
