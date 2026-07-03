# Componente Nginx - Logica de instalacion
# Se carga dinamicamente desde deploy.ps1

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

function Install-NginxComponent {
    param($cfg, $serverCfg)

    $drv = $serverCfg
    $drive = if ($drv -and (Get-Property $drv 'drive')) { Get-Property $drv 'drive' } 
             elseif ($drv -and (Get-Property $drv 'appDrive')) { Get-Property $drv 'appDrive' } 
             else { "D:" }
    $paths = Get-Property $cfg 'paths'
    if (-not $paths) {
        $ver = Get-Property $cfg 'version'
        $paths = @{
            install = "$drive\apps\nginx\$ver"
            config  = "$drive\config\nginx"
            data    = "$drive\data\nginx"
            logs    = "$drive\logs\nginx"
        }
    }

    $cache = "$drive\downloads\cache"
    New-Item -ItemType Directory -Path $cache, (Get-Property $paths 'install'), (Get-Property $paths 'config'), (Get-Property $paths 'data'), (Get-Property $paths 'logs') -Force | Out-Null

    # Crear carpeta www + index basico si no existe (separacion de datos)
    $www = Join-Path (Get-Property $paths 'data') "www"
    New-Item -ItemType Directory -Path $www -Force | Out-Null
    $index = Join-Path $www "index.html"
    if (-not (Test-Path $index)) {
        '<h1>Nginx funcionando</h1>' | Out-File $index -Encoding utf8
    }

    $exe = Join-Path (Get-Property $paths 'install') "nginx.exe"

    # 1. Descargar (idempotente)
    $ver = Get-Property $cfg 'version'
    $zip = Join-Path $cache "nginx-$ver.zip"
    if (-not (Test-Path $zip)) {
        Write-Host "[nginx] Descargando..." -ForegroundColor Cyan
        Invoke-WebRequest -Uri (Get-Property $cfg 'url') -OutFile $zip -UseBasicParsing
    }

    # 2. Extraer solo si no existe (idempotencia)
    if (-not (Test-Path $exe)) {
        Write-Host "[nginx] Extrayendo version $ver..." -ForegroundColor Cyan
        Expand-Archive -Path $zip -DestinationPath (Get-Property $paths 'install') -Force
        # El zip suele crear nginx-1.30.3\, lo movemos
        $sub = Get-ChildItem (Get-Property $paths 'install') -Directory | Where-Object { $_.Name -like "nginx*" } | Select-Object -First 1
        if ($sub) {
            Get-ChildItem $sub.FullName | Move-Item -Destination (Get-Property $paths 'install') -Force
            Remove-Item $sub.FullName -Recurse -Force
        }
    }

    # 3. Desplegar configuracion (solo si cambio)
    $tpl = Join-Path $PSScriptRoot "nginx.conf"
    $targetConf = Join-Path (Get-Property $paths 'config') "nginx.conf"

    $content = Get-Content $tpl -Raw
    $content = $content -replace '{{logPath}}',  (Get-Property $paths 'logs') `
                         -replace '{{dataPath}}', (Get-Property $paths 'data') `
                         -replace '{{port}}',     (Get-Property $cfg 'port')

    $needsUpdate = $true
    if (Test-Path $targetConf) {
        $current = Get-Content $targetConf -Raw
        if ($current -eq $content) { $needsUpdate = $false }
    }

    if ($needsUpdate) {
        Copy-Item $targetConf "$targetConf.bak" -ErrorAction SilentlyContinue -Force
        Set-Content -Path $targetConf -Value $content -Encoding UTF8
        Write-Host "[nginx] Configuracion actualizada." -ForegroundColor Green
    }

    # Probar sintaxis (compatible PS 5.1)
    & $exe -t -c $targetConf 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "[nginx] La configuracion tiene errores" }

    # 4. Servicio (NSSM preferido)
    $svcName = Get-Property (Get-Property $cfg 'service') 'name'
    $nssm = "D:\apps\nssm\nssm.exe"

    # Auto-descarga NSSM (una sola vez)
    if (-not (Test-Path $nssm) -and (Get-Property (Get-Property $cfg 'service') 'useNssm') -ne $false) {
        $nssmZip = Join-Path $cache "nssm-2.24.zip"
        if (-not (Test-Path $nssmZip)) {
            Invoke-WebRequest "https://dalthonmh.com/bin/nssm-2.24.zip" -OutFile $nssmZip -UseBasicParsing
        }
        Expand-Archive $nssmZip $cache -Force
        $found = Get-ChildItem $cache -Recurse -Filter nssm.exe | Select-Object -First 1
        if ($found) {
            New-Item -ItemType Directory (Split-Path $nssm -Parent) -Force | Out-Null
            Copy-Item $found.FullName $nssm -Force
        }
    }

    if (Test-Path $nssm) {
        # NSSM: solo reconfigura si es necesario
        $currentApp = & $nssm get $svcName Application 2>$null
        if ($currentApp -ne $exe) {
            & $nssm stop $svcName 2>$null | Out-Null
            & $nssm remove $svcName confirm 2>$null | Out-Null
            & $nssm install $svcName $exe "-c `"$targetConf`"" | Out-Null
            & $nssm set $svcName AppDirectory (Get-Property $paths 'install') | Out-Null
            & $nssm set $svcName DisplayName (Get-Property (Get-Property $cfg 'service') 'displayName') | Out-Null
            & $nssm set $svcName Start SERVICE_AUTO_START | Out-Null
            Write-Host "[nginx] Servicio (NSSM) configurado." -ForegroundColor Green
        }
    } else {
        # Fallback simple con New-Service
        $existing = Get-Service $svcName -ErrorAction SilentlyContinue
        if (-not $existing) {
            New-Service -Name $svcName `
                        -BinaryPathName "`"$exe`" -c `"$targetConf`"" `
                        -DisplayName (Get-Property (Get-Property $cfg 'service') 'displayName') `
                        -StartupType Automatic | Out-Null
        }
    }

    # Iniciar
    $svc = Get-Service $svcName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Running') {
        Start-Service $svcName -ErrorAction SilentlyContinue
    }

    Write-Host "[nginx] Listo: $(Get-Property $paths 'install')" -ForegroundColor Green
}

function Test-NginxComponent {
    param($cfg, $serverCfg)
    $svcName = Get-Property (Get-Property $cfg 'service') 'name'
    $port = Get-Property $cfg 'port'

    $svc = Get-Service $svcName -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Host ("Servicio {0} : {1}" -f $svcName, $svc.Status)
    } else {
        Write-Host "Servicio $svcName : NO EXISTE"
    }

    try {
        $resp = Invoke-WebRequest "http://localhost:$port" -TimeoutSec 6 -UseBasicParsing
        Write-Host "HTTP puerto $port : OK ($($resp.StatusCode))"
    } catch {
        Write-Host "HTTP puerto $port : No responde o error"
    }
}

# Nota: Se usa dot-sourcing desde deploy.ps1, no es necesario Export-ModuleMember
