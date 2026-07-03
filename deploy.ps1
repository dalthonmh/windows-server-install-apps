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
$server = $config.server
if ($null -eq $server) { $server = @{} }

Write-Host "=== Desplegando en $($server.name) ===" -ForegroundColor Cyan

# Cargar helpers básicos (logging simple)
function Log($msg, $color = "White") {
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts] $msg" -ForegroundColor $color
}

# Detectar componentes habilitados
$components = @()
foreach ($key in $config.Keys) {
    if ($key -in @('server')) { continue }
    if ($config[$key].enabled -eq $true) {
        $components += $key
    }
}

if ($components.Count -eq 0) {
    Log "No hay componentes habilitados en config.json" "Yellow"
    exit
}

Log "Componentes a instalar: $($components -join ', ')"

foreach ($name in $components) {
    $compCfg = $config[$name]
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
