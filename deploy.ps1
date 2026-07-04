<#
.SYNOPSIS
    Despliegue simple e idempotente para Nginx.
    Compatible con PowerShell 5.1.
#>
[CmdletBinding()]
param(
    [string]$Config = "config.psd1"
)

$ErrorActionPreference = 'Stop'

# Auto-detecta config si el default no existe (prefiere .psd1)
if (-not (Test-Path $Config)) {
    foreach ($c in @('config.psd1', 'config.json')) {
        if (Test-Path $c) { $Config = $c; break }
    }
}

if (-not (Test-Path $Config)) {
    throw "No existe el archivo de configuración: $Config (buscando config.psd1 o config.json)"
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
        # Formato recomendado y nativo para PS 5.1
        try {
            $res = Import-PowerShellDataFile -Path $path -ErrorAction Stop
        } catch {
            throw "Error importando '$path' (psd1): $_"
        }
    }
    else {
        # Soporte legacy para .json (más frágil en PS 5.1)
        $fullPath = (Resolve-Path $path).ProviderPath
        $bytes = [System.IO.File]::ReadAllBytes($fullPath)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $bytes = $bytes[3..($bytes.Length - 1)]
        }
        $jsonText = [System.Text.Encoding]::UTF8.GetString($bytes).Trim()

        if ([string]::IsNullOrWhiteSpace($jsonText) -or -not ($jsonText.StartsWith('{') -and $jsonText.EndsWith('}'))) {
            throw "El archivo no parece un objeto JSON válido: $path"
        }

        # Evitamos el problema anterior de pasar array/string enumerable
        $res = ConvertFrom-Json -InputObject $jsonText
    }

    # Normalizar: si por alguna razón se obtuvo una cadena, intentar reinterpretarla
    if ($res -is [string]) {
        $trim = $res.Trim()
        if ($trim.StartsWith('{') -and $trim.EndsWith('}')) {
            try {
                $maybe = ConvertFrom-Json -InputObject $trim -ErrorAction Stop
                if ($maybe) { $res = $maybe }
            } catch { }
        }

        # Si la cadena parece una literal de hashtable (@{ ... }), intentar evaluarla
        if ($res -is [string]) {
            $t = $res.Trim()
            if ($t.StartsWith('@{')) {
                try {
                    $eval = Invoke-Expression $t
                    if ($eval) { $res = $eval }
                } catch { }
            }
        }
    }

    return $res
}

function Log($msg, $color = "White") {
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "[$ts] $msg" -ForegroundColor $color
}

# === Carga de configuración (.psd1 nativo para PS 5.1) ===
try {
    $config = Read-Config $Config
} catch {
    Log "ERROR leyendo config: $_" "Red"
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
    Log "No hay componentes habilitados en $Config" "Yellow"
    Log "Revisa que tenga 'enabled': true (o `$true en .psd1)" "Yellow"
    Log 'Ejemplo (psd1):  nginx = @{ enabled = $true; ... }' "DarkGray"
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
