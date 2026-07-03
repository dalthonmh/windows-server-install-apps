# Componente Nginx - Logica de instalacion
# Se carga dinamicamente desde deploy.ps1

function Install-NginxComponent {
    param($cfg, $serverCfg)

    $drv = $serverCfg
    $drive = if ($drv.drive) { $drv.drive } 
             elseif ($drv.appDrive) { $drv.appDrive } 
             else { "D:" }
    $paths = $cfg.paths
    if (-not $paths) {
        $ver = $cfg.version
        $paths = @{
            install = "$drive\apps\nginx\$ver"
            config  = "$drive\config\nginx"
            data    = "$drive\data\nginx"
            logs    = "$drive\logs\nginx"
        }
    }

    $cache = "$drive\downloads\cache"
    New-Item -ItemType Directory -Path $cache, $paths.install, $paths.config, $paths.data, $paths.logs -Force | Out-Null

    # Crear carpeta www + index basico si no existe (separacion de datos)
    $www = Join-Path $paths.data "www"
    New-Item -ItemType Directory -Path $www -Force | Out-Null
    $index = Join-Path $www "index.html"
    if (-not (Test-Path $index)) {
        '<h1>Nginx funcionando</h1>' | Out-File $index -Encoding utf8
    }

    $exe = Join-Path $paths.install "nginx.exe"

    # 1. Descargar (idempotente)
    $zip = Join-Path $cache "nginx-$($cfg.version).zip"
    if (-not (Test-Path $zip)) {
        Write-Host "[nginx] Descargando..." -ForegroundColor Cyan
        Invoke-WebRequest -Uri $cfg.url -OutFile $zip -UseBasicParsing
    }

    # 2. Extraer solo si no existe (idempotencia)
    if (-not (Test-Path $exe)) {
        Write-Host "[nginx] Extrayendo version $($cfg.version)..." -ForegroundColor Cyan
        Expand-Archive -Path $zip -DestinationPath $paths.install -Force
        # El zip suele crear nginx-1.30.3\, lo movemos
        $sub = Get-ChildItem $paths.install -Directory | Where-Object { $_.Name -like "nginx*" } | Select-Object -First 1
        if ($sub) {
            Get-ChildItem $sub.FullName | Move-Item -Destination $paths.install -Force
            Remove-Item $sub.FullName -Recurse -Force
        }
    }

    # 3. Desplegar configuracion (solo si cambio)
    $tpl = Join-Path $PSScriptRoot "nginx.conf"
    $targetConf = Join-Path $paths.config "nginx.conf"

    $content = Get-Content $tpl -Raw
    $content = $content -replace '{{logPath}}',  $paths.logs `
                         -replace '{{dataPath}}', $paths.data `
                         -replace '{{port}}',     $cfg.port

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
    $svcName = $cfg.service.name
    $nssm = "D:\apps\nssm\nssm.exe"

    # Auto-descarga NSSM (una sola vez)
    if (-not (Test-Path $nssm) -and $cfg.service.useNssm -ne $false) {
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
            & $nssm set $svcName AppDirectory $paths.install | Out-Null
            & $nssm set $svcName DisplayName $cfg.service.displayName | Out-Null
            & $nssm set $svcName Start SERVICE_AUTO_START | Out-Null
            Write-Host "[nginx] Servicio (NSSM) configurado." -ForegroundColor Green
        }
    } else {
        # Fallback simple con New-Service
        $existing = Get-Service $svcName -ErrorAction SilentlyContinue
        if (-not $existing) {
            New-Service -Name $svcName `
                        -BinaryPathName "`"$exe`" -c `"$targetConf`"" `
                        -DisplayName $cfg.service.displayName `
                        -StartupType Automatic | Out-Null
        }
    }

    # Iniciar
    $svc = Get-Service $svcName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Running') {
        Start-Service $svcName -ErrorAction SilentlyContinue
    }

    Write-Host "[nginx] Listo: $($paths.install)" -ForegroundColor Green
}

function Test-NginxComponent {
    param($cfg, $serverCfg)
    $svcName = $cfg.service.name
    $port = $cfg.port

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
