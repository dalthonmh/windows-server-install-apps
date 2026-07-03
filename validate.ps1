<#
.SYNOPSIS
    Validacion simple despues del despliegue.
#>
param([string]$Config = "config.json")

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

    $parsed = ConvertFrom-Json -InputObject (,$jsonText)
    $keys = Get-TopLevelKeys $parsed
    if ($keys.Count -gt 0) {
        return $parsed
    }

    Add-Type -AssemblyName System.Web.Extensions
    $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $serializer.RecursionLimit = 100
    return $serializer.DeserializeObject($jsonText)
}

$rawConfig = $null
try {
    $rawConfig = Read-ConfigJson $Config
} catch {
    Write-Host "ERROR parseando JSON: $_" -ForegroundColor Red
    exit 1
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
    if (-not (Test-IsEnabled $enabled)) { continue }

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
