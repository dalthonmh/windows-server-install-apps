<#
.SYNOPSIS
    Despliegue simple e idempotente para Nginx (y futuros componentes).
    Edita config.json y ejecuta este archivo.
    Compatible con PowerShell 5.1 (Windows Server).
#>
[CmdletBinding()]
param(
    [string]$Config = "config.json"
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Config)) {
    throw "No existe el archivo de configuracion: $Config"
}

# =====================================================
# Funciones seguras para PSCustomObject y Hashtable (PS 5.1 compatible)
# =====================================================

function Get-TopLevelKeys($obj) {
    if ($null -eq $obj) { return @() }
    if ($obj -is [hashtable]) { return @($obj.Keys) }
    if ($obj -is [psobject]) { return @($obj.PSObject.Properties.Name) }
    return @()
}

function Get-Property($obj, [string]$name) {
    if ($null -eq $obj -or [string]::IsNullOrEmpty($name)) { return $null }
    if ($obj -is [hashtable]) {
        if ($obj.ContainsKey($name)) { return $obj[$name] }
        return $null
    }
    if ($obj -is [psobject]) {
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

# =====================================================
# Cargar JSON de forma robusta (PS 5.1)
# =====================================================

try {
    # Usar File.ReadAllText para evitar problemas de encoding/BOM de Get-Content
    $fullPath = (Resolve-Path $Config).ProviderPath
    $jsonText = [System.IO.File]::ReadAllText($fullPath, [Text.Encoding]::UTF8)
    $rawConfig = ConvertFrom-Json -InputObject $jsonText
} catch {
    throw "Error leyendo o parseando el JSON: $($_.Exception.Message)"
}

# Trabajamos directamente con el objeto de ConvertFrom-Json (PSCustomObject)
$config = $rawConfig

$allKeys = Get-TopLevelKeys $config
Log "Claves en config.json: $($allKeys -join ', ')" "DarkGray"

# =====================================================
# Preparar Server
# =====================================================

$server = Get-Property $config 'server'
if (-not $server) { $server = @{} }

# Normalizar claves antiguas
$driveVal = Get-Property $server 'drive'
if (-not $driveVal) {
    $driveVal = Get-Property $server 'appDrive'
}
if (-not $driveVal) { $driveVal = "D:" }

$serverName = Get-Property $server 'name'
if (-not $serverName) { $serverName = "(sin nombre)" }

Write-Host "=== Desplegando en $serverName ===" -ForegroundColor Cyan
Log "Server detectado: name='$serverName' drive='$driveVal'" "DarkGray"

# =====================================================
# Detectar componentes habilitados (soporta plano o "components")
# =====================================================

$searchSpace = $config
$componentsSection = Get-Property $config 'components'
if ($componentsSection) {
    $searchSpace = $componentsSection
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

# =====================================================
# Ejecutar cada componente
# =====================================================

foreach ($name in $components) {
    $compCfg = Get-Property $searchSpace $name
    $compDir = Join-Path "components" $name
    $compScript = Join-Path $compDir "$name.ps1"

    if (-not (Test-Path $compScript)) {
        Log "No existe logica para '$name' → $compScript" "Red"
        continue
    }

    Log "Procesando componente: $name" "Cyan"

    # Dot-source
    . $compScript

    $funcName = "Install-" + $name.Substring(0,1).ToUpper() + $name.Substring(1) + "Component"

    if (Get-Command $funcName -ErrorAction SilentlyContinue) {
        & $funcName -cfg $compCfg -serverCfg $server
    } else {
        Log "No se encontro la funcion $funcName en $compScript" "Yellow"
    }
}

Log "Despliegue terminado." "Green"
Log "Ejecuta .\validate.ps1 para verificar." "Yellow"