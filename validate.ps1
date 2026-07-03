<#
.SYNOPSIS
    Validacion simple despues del despliegue.
#>
param([string]$Config = "config.psd1")

# Auto-detecta config si es necesario
if (-not (Test-Path $Config)) {
    foreach ($c in @('config.psd1', 'config.json')) {
        if (Test-Path $c) { $Config = $c; break }
    }
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
        # Soporte para JSON legacy
        $fullPath = (Resolve-Path $path).ProviderPath
        $bytes = [System.IO.File]::ReadAllBytes($fullPath)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $bytes = $bytes[3..($bytes.Length - 1)]
        }
        $jsonText = [System.Text.Encoding]::UTF8.GetString($bytes).Trim()

        if ([string]::IsNullOrWhiteSpace($jsonText) -or -not ($jsonText.StartsWith('{') -and $jsonText.EndsWith('}'))) {
            throw "El archivo no parece un objeto JSON válido: $path"
        }

        return (ConvertFrom-Json -InputObject $jsonText)
    }
}

$rawConfig = $null
try {
    $rawConfig = Read-Config $Config
} catch {
    Write-Host "ERROR cargando config: $_" -ForegroundColor Red
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
