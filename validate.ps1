param([string]$Config = "config.json")

$config = Get-Content $Config -Raw | ConvertFrom-Json -AsHashtable

Write-Host "=== Validación ===" -ForegroundColor Cyan

foreach ($key in $config.Keys) {
    if ($key -eq 'server') { continue }
    if (-not $config[$key].enabled) { continue }

    $name = $key
    $compScript = ".\components\$name\$name.ps1"

    if (Test-Path $compScript) {
        . $compScript
        $testFunc = "Test-" + $name.Substring(0,1).ToUpper() + $name.Substring(1) + "Component"
        if (Get-Command $testFunc -ErrorAction SilentlyContinue) {
            & $testFunc -cfg $config[$key] -serverCfg $config.server
        }
    }

    # Validación básica de servicio
    $svcName = $config[$key].service.name
    if ($svcName) {
        $svc = Get-Service $svcName -ErrorAction SilentlyContinue
        Write-Host "$svcName : $($svc.Status)"
    }
}

Write-Host "Validación finalizada."
