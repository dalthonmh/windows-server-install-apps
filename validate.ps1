<#
.SYNOPSIS
    Validacion simple despues del despliegue.
#>
param([string]$Config = "config.psd1")

if (-not (Test-Path $Config)) {
    throw "Configuration file not found: $Config (expected config.psd1)"
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
        throw "No existe el archivo: $path"
    }

    $ext = [System.IO.Path]::GetExtension($path).ToLower()

    if ($ext -eq '.psd1') {
        try {
            return Import-PowerShellDataFile -Path $path -ErrorAction Stop
        } catch {
            throw "Error importando '$path' (psd1): $_"
        }
    }
    else {
        throw "Only config.psd1 is supported. JSON support was removed."
    }
}

$rawConfig = $null
try {
    $rawConfig = Read-Config $Config
} catch {
    Write-Host "ERROR loading config: $_" -ForegroundColor Red
    exit 1
}

Write-Host "=== Validation ===" -ForegroundColor Cyan

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
            $dl = Get-Property $rawConfig 'downloads'
            & $testFunc -cfg $comp -serverCfg (Get-Property $rawConfig 'server') -downloads $dl
        }
    }

    $svc = Get-Property $comp 'service'
    $svcName = Get-Property $svc 'name'
    if ($svcName) {
        $s = Get-Service $svcName -ErrorAction SilentlyContinue
        if ($s) {
            Write-Host "$svcName : $($s.Status)"
        } else {
            Write-Host "$svcName : DOES NOT EXIST"
        }
    }
}

Write-Host "Validation finished."
