param([string]$Config = "config.json")

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

Write-Host "=== Validación ===" -ForegroundColor Cyan

# Soporte flexible (igual que deploy.ps1)
$searchSpace = $config
if ($config.components) {
    $searchSpace = $config.components
}

foreach ($key in $searchSpace.Keys) {
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

    # Validación básica de servicio
    $svcName = $searchSpace[$key].service.name
    if ($svcName) {
        $svc = Get-Service $svcName -ErrorAction SilentlyContinue
        Write-Host "$svcName : $($svc.Status)"
    }
}

Write-Host "Validación finalizada."
