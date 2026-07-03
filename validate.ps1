<#
.SYNOPSIS
    Validacion simple despues del despliegue.
#>
param([string]$Config = "config.json")

$fullPath = (Resolve-Path $Config).ProviderPath
$jsonText = [System.IO.File]::ReadAllText($fullPath)

$rawConfig = $null
try {
    $rawConfig = ConvertFrom-Json -InputObject $jsonText
} catch {
    Write-Host "ERROR parseando JSON: $_" -ForegroundColor Red
    exit 1
}

function Get-TopLevelKeys($obj) {
    if ($null -eq $obj) { return @() }
    if ($obj -is [hashtable]) { return @($obj.Keys) }
    if ($obj.PSObject) { return @($obj.PSObject.Properties.Name) }
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

Write-Host "=== Validacion ===" -ForegroundColor Cyan

$searchSpace = $rawConfig
$compSection = Get-Property $rawConfig 'components'
if ($compSection) {
    $searchSpace = $compSection
}

$searchKeys = Get-TopLevelKeys $searchSpace

foreach ($key in $searchKeys) {
    if ($key -eq 'server') { continue }
    $comp = Get-Property $searchSpace $key
    $enabled = Get-Property $comp 'enabled'
    if (-not $enabled) { continue }

    $name = $key
    $compScript = ".\components\$name\$name.ps1"

    if (Test-Path $compScript) {
        . $compScript
        $testFunc = "Test-" + $name.Substring(0,1).ToUpper() + $name.Substring(1) + "Component"
        if (Get-Command $testFunc -ErrorAction SilentlyContinue) {
            & $testFunc -cfg $comp -serverCfg (Get-Property $rawConfig 'server')
        }
    }

    $svc = Get-Property $comp 'service'
    $svcName = Get-Property $svc 'name'
    if ($svcName) {
        $s = Get-Service $svcName -ErrorAction SilentlyContinue
        if ($s) {
            Write-Host "$svcName : $($s.Status)"
        } else {
            Write-Host "$svcName : NO EXISTE"
        }
    }
}

Write-Host "Validacion finalizada."
