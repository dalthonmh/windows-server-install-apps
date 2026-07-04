<#
.SYNOPSIS
    Despliegue simple e idempotente para Nginx.
    Compatible con PowerShell 5.1.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = "config.psd1"
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ConfigPath)) {
    throw "Configuration file not found: $ConfigPath (expected config.psd1)"
}

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
    if (-not (Test-Path $path)) {
        throw "File does not exist: $path"
    }

    $ext = [System.IO.Path]::GetExtension($path).ToLower()

    if ($ext -eq '.psd1') {
        # Formato recomendado y nativo para PS 5.1
        try {
            $res = Import-PowerShellDataFile -Path $path -ErrorAction Stop
        } catch {
            throw "Error importando '$path' (psd1): $_"
        }
    }
    else {
        throw "Only .psd1 format is supported (config.psd1). JSON support was removed."
    }

    # Normalizar: si por alguna razon se obtuvo una cadena, intentar reinterpretarla
    if ($res -is [string]) {
        $trim = $res.Trim()
        if ($trim.StartsWith('{') -and $trim.EndsWith('}')) {
            try {
                $maybe = ConvertFrom-Json -InputObject $trim -ErrorAction Stop
                if ($maybe) { $res = $maybe }
            } catch { }
        }

        # Si la cadena parece una literal de hashtable (@{ ... }), intentar evaluarla
        if ($res -is [string]) {
            $t = $res.Trim()
            if ($t.StartsWith('@{')) {
                try {
                    $eval = Invoke-Expression $t
                    if ($eval) { $res = $eval }
                } catch { }
            }
        }
    }

    return $res
}

function Log($msg, $color = "White") {
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts] $msg" -ForegroundColor $color
}

# === Carga de configuracion (.psd1 nativo para PS 5.1) ===
try {
    $config = Read-Config $ConfigPath
} catch {
    Log "ERROR reading config: $_" "Red"
    throw
}

Log "Config object type: $($config.GetType().FullName)" "Yellow"

$allKeys = Get-TopLevelKeys $config
Log "Keys in ${ConfigPath}: $($allKeys -join ', ')" "DarkGray"

# Load shared download helper (ensures files are downloaded only once to cache)
. (Join-Path $PSScriptRoot "lib\Download-Cached.ps1")

$server = Get-Property $config 'server'
if (-not $server) { $server = @{} }

$driveVal = Get-Property $server 'drive'
if (-not $driveVal) { $driveVal = Get-Property $server 'appDrive' }
if (-not $driveVal) { $driveVal = "D:" }

$serverName = Get-Property $server 'name'
if (-not $serverName) { $serverName = "(sin nombre)" }

Write-Host "=== Deploying on $serverName ===" -ForegroundColor Cyan
Log "Server detected: name='$serverName' drive='$driveVal'" "DarkGray"

# Buscar componentes
$searchSpace = $config
$compSection = Get-Property $config 'components'
if ($compSection) {
    $searchSpace = $compSection
    Log "Using 'components' structure" "DarkGray"
}

$searchKeys = Get-TopLevelKeys $searchSpace

$components = @()
foreach ($key in $searchKeys) {
    if ($key -eq 'server') { continue }
    $comp = Get-Property $searchSpace $key
    $enabled = Get-Property $comp 'enabled'
    if ($comp -and (Test-IsEnabled $enabled)) {
        $components += $key
    }
}

if ($components.Count -eq 0) {
    Log "No enabled components found in $ConfigPath" "Yellow"
    Log "Make sure components have 'enabled': true (or `$true in .psd1)" "Yellow"
    Log 'Example (psd1):  nginx = @{ enabled = $true; ... }' "DarkGray"
    exit
}

Log "Components to install: $($components -join ', ')" "Cyan"

foreach ($name in $components) {
    $compCfg = Get-Property $searchSpace $name
    $compDir = Join-Path "components" $name
    $compScript = Join-Path $compDir "$name.ps1"

    if (-not (Test-Path $compScript)) {
        Log "No logic found for '$name' → $compScript" "Red"
        continue
    }

    Log "Processing component: $name" "Cyan"

    . $compScript

    $funcName = "Install-" + $name.Substring(0,1).ToUpper() + $name.Substring(1) + "Component"

    $downloads = Get-Property $config 'downloads'

    if (Get-Command $funcName -ErrorAction SilentlyContinue) {
        & $funcName -cfg $compCfg -serverCfg $server -downloads $downloads
    } else {
        Log "Function not found: $funcName" "Yellow"
    }
}

Log "Deployment finished." "Green"
Log "Run .\validate.ps1 to verify." "Yellow"
