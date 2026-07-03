<#
.SYNOPSIS
    Despliegue simple e idempotente.
    Edita config.json y ejecuta este archivo.
#>
[CmdletBinding()]
param(
    [string]$Config = "config.json"
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Config)) { throw "No existe $Config" }

# Compatible con PowerShell 5.1 (Windows Server) y PowerShell 7+
# ConvertFrom-Json en PS 5.1 no tiene -AsHashtable
$rawJson = Get-Content $Config -Raw | ConvertFrom-Json

function ConvertTo-Hashtable {
    param($Object)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IEnumerable] -and -not ($Object -is [string])) {
        $collection = @(
            foreach ($item in $Object) { ConvertTo-Hashtable $item }
        )
        return $collection
    }
    elseif ($Object -is [psobject]) {
        $hash = @{}
        foreach ($prop in $Object.PSObject.Properties) {
            $hash[$prop.Name] = ConvertTo-Hashtable $prop.Value
        }
        return $hash
    }
    else {
        return $Object
    }
}

$config = ConvertTo-Hashtable $rawJson

# Soporte flexible para server (acepta "name" o "appDrive" de versiones antiguas)
$server = if ($config.server) { $config.server } else { @{} }

# Normalizar drive / appDrive
if (-not $server.drive -and $server.appDrive) {
    $server.drive = $server.appDrive
}

$serverName = if ($server.name) { $server.name } else { "(sin nombre)" }
Write-Host "=== Desplegando en $serverName ===" -ForegroundColor Cyan

# Cargar helpers básicos (logging simple)
function Log($msg, $color = "White") {
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts] $msg" -ForegroundColor $color
}

# Debug: mostrar qué encontró
Log "Claves en config.json: $($config.Keys -join ', ')" "DarkGray"
Log "Server detectado: name='$($server.name)' drive='$($server.drive)'" "DarkGray"

# === Lógica de detección de componentes (flexible) ===
# Soporta dos formatos:
# 1. Plano (recomendado):  { "server": {...}, "nginx": { "enabled": true, ... } }
# 2. Con wrapper:         { "server": {...}, "components": { "nginx": { "enabled": true } } }

$searchSpace = $config
if ($config.components) {
    $searchSpace = $config.components
    Log "Usando estructura con 'components'" "DarkGray"
}

$components = @()
foreach ($key in $searchSpace.Keys) {
    if ($key -eq 'server') { continue }
    $comp = $searchSpace[$key]
    if ($comp -and $comp.enabled -eq $true) {
        $components += $key
    }
}

if ($components.Count -eq 0) {
    Log "No hay componentes habilitados en config.json" "Yellow"
    Log "Revisa que el bloque del servicio tenga 'enabled': true" "Yellow"
    Log "Ejemplo esperado:" "DarkGray"
    Log '  "nginx": { "enabled": true, ... }' "DarkGray"
    exit
}

Log "Componentes a instalar: $($components -join ', ')"

foreach ($name in $components) {
    $compCfg = $searchSpace[$name]
    $compDir = Join-Path "components" $name
    $compScript = Join-Path $compDir "$name.ps1"

    if (-not (Test-Path $compScript)) {
        Log "No existe lógica para '$name' en $compScript" "Red"
        continue
    }

    Log "Procesando componente: $name" "Cyan"

    # Cargar el script del componente (dot-source simple)
    . $compScript

    # Convención: "nginx" → Install-NginxComponent
    $funcName = "Install-" + $name.Substring(0,1).ToUpper() + $name.Substring(1) + "Component"

    if (Get-Command $funcName -ErrorAction SilentlyContinue) {
        & $funcName -cfg $compCfg -serverCfg $server
    } else {
        Log "Función esperada no encontrada: $funcName" "Yellow"
    }
}

Log "Despliegue terminado." "Green"
Log "Ejecuta .\validate.ps1 para verificar." "Yellow"
