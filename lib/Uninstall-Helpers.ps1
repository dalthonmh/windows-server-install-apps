# Shared uninstall helpers
# Dot-source this from uninstall.ps1

function Remove-SymlinkIfExists {
    param([string]$Path)
    if (Test-Path $Path) {
        try {
            $item = Get-Item $Path -ErrorAction SilentlyContinue
            if ($item -and $item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                if ($WhatIf) {
                    Write-Host "[uninstall] WhatIf: Remove symlink $Path" -ForegroundColor Yellow
                } else {
                    Remove-Item $Path -Force -ErrorAction SilentlyContinue
                    Write-Host "[uninstall] Removed symlink: $Path" -ForegroundColor Green
                }
            }
        } catch {
            Write-Host "[uninstall] Could not remove symlink $Path : $_" -ForegroundColor Red
        }
    }
}

function Remove-FromSystemPath {
    param([string]$PathToRemove)
    if ([string]::IsNullOrWhiteSpace($PathToRemove)) { return }

    try {
        $current = [Environment]::GetEnvironmentVariable("Path", "Machine")
        if ($current -like "*$PathToRemove*") {
            $parts = $current -split ';' | Where-Object { $_.Trim() -ne '' -and $_ -ne $PathToRemove }
            $newPath = ($parts -join ';').TrimEnd(';')
            if (-not $WhatIf) {
                [Environment]::SetEnvironmentVariable("Path", $newPath, "Machine")
            }
            Write-Host "[uninstall] Removed from system PATH: $PathToRemove" -ForegroundColor Green
        }
    } catch {
        Write-Host "[uninstall] Failed to clean PATH for $PathToRemove (run as Administrator if needed)." -ForegroundColor Yellow
    }
}

function Stop-And-Remove-Service {
    param(
        [string]$ServiceName,
        [string]$NssmPath
    )

    if (-not $ServiceName) { return }

    $svc = Get-Service $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Host "[uninstall] Service '$ServiceName' does not exist." -ForegroundColor DarkGray
        return
    }

    if ($WhatIf) {
        Write-Host "[uninstall] WhatIf: Would stop and remove service $ServiceName" -ForegroundColor Yellow
        return
    }

    Write-Host "[uninstall] Stopping service $ServiceName..." -ForegroundColor Cyan
    Stop-Service $ServiceName -Force -ErrorAction SilentlyContinue | Out-Null

    $useNssm = $false
    if ($NssmPath -and (Test-Path $NssmPath)) {
        $useNssm = $true
    }

    if ($useNssm) {
        Write-Host "[uninstall] Removing service via NSSM: $ServiceName" -ForegroundColor Cyan
        & $NssmPath remove $ServiceName confirm 2>&1 | Out-Null
    } else {
        Write-Host "[uninstall] Removing service (native): $ServiceName" -ForegroundColor Cyan
        try {
            & sc.exe delete $ServiceName | Out-Null
        } catch {
            Remove-Service -Name $ServiceName -ErrorAction SilentlyContinue
        }
    }

    Start-Sleep -Milliseconds 600
    $svc = Get-Service $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Host "[uninstall] Service '$ServiceName' removed." -ForegroundColor Green
    } else {
        Write-Host "[uninstall] Service '$ServiceName' may still exist (may need reboot)." -ForegroundColor Yellow
    }
}
