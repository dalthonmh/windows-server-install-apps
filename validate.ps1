<#
.SYNOPSIS
    Validacion simple despues del despliegue.
#>
param([string]$Config = "config.json")

$rawJson = Get-Content $Config -Raw | ConvertFrom-Json

function ConvertTo-Hashtable {
    param($Object)

    if ($null -eq $Object) { return $null }

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

$config = ConvertTo-Hashtable $rawJson

if (-not ($config -is [hashtable])) {
    Write-Host "ADVERTENCIA: Conversion fallida. Tipo: $($config.GetType().Name)" -ForegroundColor Yellow
}

Write-Host "=== Validacion ===" -ForegroundColor Cyan

$searchSpace = $config
if ($config.components) {
    $searchSpace = $config.components
}

$searchKeys = Get-ConfigKeys $searchSpace

foreach ($key in $searchKeys) {
    if ($key -eq 'server') { continue }
    if (-not $searchSpace[$key].enabled) { continue }

    $name = $key
    $compScript = ".\components\$name\$name.ps1"

    if (Test-Path $compScript) {
        . $compScript
        $testFunc = "Test-" + $name.Substring(0,1).ToUpper() + $name.Substring(1) + "Component"
        if (Get-Command $testFunc -ErrorAction SilentlyContinue) {
            & $testFunc -cfg $searchSpace[$key] -serverCfg $config.server
        }
    }

    # Validacion basica de servicio
    $svcName = $searchSpace[$key].service.name
    if ($svcName) {
        $svc = Get-Service $svcName -ErrorAction SilentlyContinue
        if ($svc) {
            Write-Host "$svcName : $($svc.Status)"
        } else {
            Write-Host "$svcName : NO EXISTE"
        }
    }
}

Write-Host "Validacion finalizada."
