<#
.SYNOPSIS
    Despliegue simple e idempotente para Nginx (y futuros componentes).
    Edita config.json y ejecuta este archivo.
    Compatible con PowerShell 5.1 (Windows Server) y PowerShell 7.
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
# Funciones base (definidas temprano)
# =====================================================

function Log($msg, $color = "White") {
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts] $msg" -ForegroundColor $color
}

function ConvertTo-Hashtable {
    param($Object)

    if ($null -eq $Object) { return $null }

    # CRITICO: Revisar psobject ANTES que IEnumerable
    # porque en PS 5.1 PSCustomObject tambien es IEnumerable
    if ($Object -is [psobject]) {
        $hash = @{}
        foreach ($prop in $Object.PSObject.Properties) {
            $hash[$prop.Name] = ConvertTo-Hashtable $prop.Value
        }
        return $hash
    }

    if ($Object -is [System.Collections.IEnumerable] -and -not ($Object -is [string])) {
        $collection = @(
            foreach ($item in $Object) { ConvertTo-Hashtable $item }
        )
        return $collection
    }

    return $Object
}

function Get-ConfigKeys($obj) {
    if ($null -eq $obj) { return @() }
    if ($obj -is [hashtable]) { return @($obj.Keys) }
    if ($obj -is [psobject])  { return @($obj.PSObject.Properties.Name) }
    return @()
}

# =====================================================
# Cargar y convertir configuracion
# =====================================================

$rawJson = Get-Content $Config -Raw | ConvertFrom-Json
$config  = ConvertTo-Hashtable $rawJson

if (-not ($config -is [hashtable])) {
    Write-Host "ADVERTENCIA: No se pudo convertir a hashtable. Usando objeto original." -ForegroundColor Yellow
    if ($rawJson -is [psobject]) {
        $config = $rawJson
    }
}

# =====================================================
# Preparar Server
# =====================================================

$server = if ($config.server) { $config.server } else { @{} }

# Normalizar claves antiguas
if (-not $server.drive -and $server.appDrive) {
    $server.drive = $server.appDrive
}
if (-not $server.name -and $server.serverName) {
    $server.name = $server.serverName
}

$serverName = if ($server.name) { $server.name } else { "(sin nombre)" }
Write-Host "=== Desplegando en $serverName ===" -ForegroundColor Cyan

$allKeys = Get-ConfigKeys $config
Log "Claves en config.json: $($allKeys -join ', ')" "DarkGray"
Log "Server detectado: name='$($server.name)' drive='$($server.drive)'" "DarkGray"

# =====================================================
# Detectar componentes habilitados
# Soporta formato plano o con "components"
# =====================================================

$searchSpace = $config
if ($config.components) {
    $searchSpace = $config.components
    Log "Usando estructura con 'components'" "DarkGray"
}

$searchKeys = Get-ConfigKeys $searchSpace

$components = @()
foreach ($key in $searchKeys) {
    if ($key -eq 'server') { continue }
    $comp = $searchSpace[$key]
    if ($comp -and $comp.enabled -eq $true) {
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
    $compCfg = $searchSpace[$name]
    $compDir = Join-Path "components" $name
    $compScript = Join-Path $compDir "$name.ps1"

    if (-not (Test-Path $compScript)) {
        Log "No existe logica para '$name' → $compScript" "Red"
        continue
    }

    Log "Procesando componente: $name" "Cyan"

    # Dot-source del script del componente
    . $compScript

    # Nombre de funcion esperado: Install-NginxComponent, Install-ApacheComponent, etc.
    $funcName = "Install-" + $name.Substring(0,1).ToUpper() + $name.Substring(1) + "Component"

    if (Get-Command $funcName -ErrorAction SilentlyContinue) {
        & $funcName -cfg $compCfg -serverCfg $server
    } else {
        Log "No se encontro la funcion $funcName en $compScript" "Yellow"
    }
}

Log "Despliegue terminado." "Green"
Log "Ejecuta .\validate.ps1 para verificar." "Yellow"
