<#
.SYNOPSIS
    Despliegue simple e idempotente para Nginx.
    Compatible con PowerShell 5.1.
#>
[CmdletBinding()]
param(
    [string]$Config = "config.json"
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Config)) {
    throw "No existe el archivo: $Config"
}

function Get-TopLevelKeys($obj) {
    if ($null -eq $obj) { return @() }
    if ($obj -is [hashtable]) { return @($obj.Keys) }
    if ($obj.PSObject) {
        return @($obj.PSObject.Properties.Name)
    }
    return @()
}

function Get-Property($obj, [string]$name) {
    if ($null -eq $obj -or [string]::IsNullOrEmpty($name)) { return $null }
    if ($obj -is [hashtable]) {
        if ($obj.ContainsKey($name)) { return $obj[$name] }
        return $null
    }
    if ($obj.PSObject) {
        $prop = $obj.PSObject.Properties[$name]
        if ($prop) { return $prop.Value }
        return $null
    }
    return $null
}

function Log($msg, $color = "White") {
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts] $msg" -ForegroundColor $color
}

# === Carga robusta del JSON para PS 5.1 ===
$fullPath = (Resolve-Path $Config).ProviderPath
$jsonText = [System.IO.File]::ReadAllText($fullPath)

# Debug: mostrar lo que realmente leyo
Log "Longitud del archivo JSON: $($jsonText.Length)" "DarkGray"
if ($jsonText.Length -gt 0) {
    $preview = $jsonText.Substring(0, [Math]::Min(200, $jsonText.Length))
    Log "Primeros chars del JSON: $preview" "DarkGray"
}

$rawConfig = $null
try {
    $rawConfig = ConvertFrom-Json -InputObject $jsonText
} catch {
    Log "ERROR al hacer ConvertFrom-Json: $_" "Red"
    throw
}

Log "Tipo de objeto despues de ConvertFrom-Json: $($rawConfig.GetType().FullName)" "Yellow"

$config = $rawConfig

$allKeys = Get-TopLevelKeys $config
Log "Claves en config.json: $($allKeys -join ', ')" "DarkGray"

$server = Get-Property $config 'server'
if (-not $server) { $server = @{} }

$driveVal = Get-Property $server 'drive'
if (-not $driveVal) { $driveVal = Get-Property $server 'appDrive' }
if (-not $driveVal) { $driveVal = "D:" }

$serverName = Get-Property $server 'name'
if (-not $serverName) { $serverName = "(sin nombre)" }

Write-Host "=== Desplegando en $serverName ===" -ForegroundColor Cyan
Log "Server detectado: name='$serverName' drive='$driveVal'" "DarkGray"

# Buscar componentes
$searchSpace = $config
$compSection = Get-Property $config 'components'
if ($compSection) {
    $searchSpace = $compSection
    Log "Usando estructura con 'components'" "DarkGray"
}

$searchKeys = Get-TopLevelKeys $searchSpace

$components = @()
foreach ($key in $searchKeys) {
    if ($key -eq 'server') { continue }
    $comp = Get-Property $searchSpace $key
    $enabled = Get-Property $comp 'enabled'
    if ($comp -and $enabled -eq $true) {
        $components += $key
    }
}

if ($components.Count -eq 0) {
    Log "No hay componentes habilitados en config.json" "Yellow"
    Log "Revisa que tenga 'enabled': true" "Yellow"
    Log 'Ejemplo: "nginx": { "enabled": true, ... }' "DarkGray"
    exit
}

Log "Componentes a instalar: $($components -join ', ')" "Cyan"

foreach ($name in $components) {
    $compCfg = Get-Property $searchSpace $name
    $compDir = Join-Path "components" $name
    $compScript = Join-Path $compDir "$name.ps1"

    if (-not (Test-Path $compScript)) {
        Log "No existe logica para '$name' → $compScript" "Red"
        continue
    }

    Log "Procesando componente: $name" "Cyan"

    . $compScript

    $funcName = "Install-" + $name.Substring(0,1).ToUpper() + $name.Substring(1) + "Component"

    if (Get-Command $funcName -ErrorAction SilentlyContinue) {
        & $funcName -cfg $compCfg -serverCfg $server
    } else {
        Log "No se encontro la funcion $funcName" "Yellow"
    }
}

Log "Despliegue terminado." "Green"
Log "Ejecuta .\validate.ps1 para verificar." "Yellow"
