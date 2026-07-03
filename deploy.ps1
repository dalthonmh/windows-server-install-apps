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

function Read-ConfigJson([string]$path) {
    $fullPath = (Resolve-Path $path).ProviderPath
    $bytes = [System.IO.File]::ReadAllBytes($fullPath)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $bytes = $bytes[3..($bytes.Length - 1)]
    }
    $jsonText = [System.Text.Encoding]::UTF8.GetString($bytes).Trim()

    if ([string]::IsNullOrWhiteSpace($jsonText)) {
        throw "El archivo JSON esta vacio: $path"
    }
    if (-not ($jsonText.StartsWith('{') -and $jsonText.EndsWith('}'))) {
        throw "El archivo JSON debe ser un objeto (empezar con { y terminar con })"
    }

    # PS 5.1: el string implementa IEnumerable<char> y ConvertFrom-Json lo trocea.
    # La coma fuerza un solo argumento con el JSON completo.
    $parsed = ConvertFrom-Json -InputObject (,$jsonText)

    $keys = Get-TopLevelKeys $parsed
    if ($keys.Count -gt 0) {
        return $parsed
    }

    # Fallback para PS 5.1 cuando ConvertFrom-Json no deserializa propiedades.
    Add-Type -AssemblyName System.Web.Extensions
    $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $serializer.RecursionLimit = 100
    return $serializer.DeserializeObject($jsonText)
}

function Log($msg, $color = "White") {
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts] $msg" -ForegroundColor $color
}

# === Carga robusta del JSON para PS 5.1 ===
try {
    $config = Read-ConfigJson $Config
} catch {
    Log "ERROR leyendo config.json: $_" "Red"
    throw
}

Log "Tipo de objeto config: $($config.GetType().FullName)" "Yellow"

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
    if ($comp -and (Test-IsEnabled $enabled)) {
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
