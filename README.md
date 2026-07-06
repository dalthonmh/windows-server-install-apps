# Windows Server Install

Instalador simple, declarativo e idempotente para Nginx (y otros servicios) en Windows Server.

![Imagen de ejecucion](/docs/ejecution-sample.png)

## Ejecutar (4 pasos)

> **Nota**: Funciona en PowerShell 5.1 (el que viene por defecto en Windows Server) y PowerShell 7.

1. En el servidor Windows (PowerShell como Administrador):

```powershell
Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
```

2. Clona o copia este repo:

```powershell
git clone https://github.com/dalthonmh/windows-server-install-apps.git
```

3. Edita `config.psd1` (solo este archivo):

```powershell
@{
    server = @{
        name  = "MI-SERVIDOR"
        drive = "D:"
    }

    # URL base para todos los binarios (nginx, nssm, etc.)
    downloads = @{
        base = "https://dalthonmh.com/bin"
    }

    nssm = @{
        enabled = $true
        version = "2.24"
    }

    nginx = @{
        enabled = $true
        version = "1.30.3"

        paths = @{
            install = "D:\apps\nginx\1.30.3"
            config  = "D:\config\nginx"
            data    = "D:\data\nginx"
            logs    = "D:\logs\nginx"
        }

        port = 80

        service = @{
            name        = "nginx"
            displayName = "Nginx Web Server"
            useNssm     = $true
        }
    }
}
```

Importante: usa `$true` y rutas con `\`. Solo se soporta `config.psd1`.

4. Ejecuta:

```powershell
.\deploy.ps1
```

Eso es todo. El script es **idempotente**: puedes correrlo muchas veces. Solo hace lo necesario.

## Validar

```powershell
.\validate.ps1
```

## Agregar un nuevo servicio

1. Agrega el bloque en `config.psd1` (usa `downloads.base` cuando sea posible):

   ```powershell
   apache = @{
       enabled = $true
       version = "2.4"
       port    = 81
       paths   = @{ ... }
       service = @{ name = "apache"; displayName = "Apache" }
   }
   ```

2. Crea carpeta `components/apache/`

3. Copia la estructura de un componente existente (ej. `nginx` o `nssm`).

4. Implementa:
   - `Install-ApacheComponent`
   - `Test-ApacheComponent`

El framework detecta automáticamente cualquier componente habilitado en `config.psd1`.

Componentes recomendados:

- `nssm` para wrappers de servicio (separado de la app).
- Tu app (nginx, iis, etc.).

## Estructura recomendada (modular y escalable)

```
D:\
├── tools\
├── apps\
│   ├── catastro\
│   ├── academico-backend\
│   ├── academico-estudiante\
│   ├── academico-academico\
│   ├── academico-docente\
│   └── ...
├── www\
│   ├── catastro\
│   ├── academico-estudiante\
│   ├── academico-academico\
│   └── ...
├── config\
│   └── nginx\
├── logs\
├── backups\
└── deploy\
```

## Paths en el servidor (separación clara)

- App (versionada): `D:\tools\nginx\1.30.3`
- Current (symlink): `D:\tools\nginx\nginx-current` → apunta a la versión activa
- Config persistente (fácil de editar y sobrevive upgrades): `D:\config\nginx\nginx.conf` + `sites-enabled\*.conf`
- Logs: `D:\tools\logs\nginx` (o donde configures)

El symlink `nginx-current` + config externa te permite:

- Actualizar Nginx fácilmente (nueva versión → symlink nuevo → reiniciar)
- Referenciar siempre la misma ruta: `tools\nginx\current\nginx.exe -c config\nginx\nginx.conf`
- Mantener tus vhosts en `config\nginx\sites-enabled\` sin que se pierdan en upgrades.

## Componentes separados (recomendado)

- `nssm` → instala NSSM y lo agrega al PATH del sistema.
- `php` → instala PHP 8 thread-safe (x64) y lo agrega al PATH.
- `composer` → instala Composer automáticamente (sin GUI). Descarga composer.phar + crea wrapper + agrega al PATH.
- `neovim` → instala Neovim (recomendado). Usa el zip portable y lo agrega al PATH.
- `apache` → instala Apache 2.4 (Apache Lounge) en puerto 81 + integracion basica PHP.
- `nginx` → instala Nginx y lo registra como servicio (puede usar NSSM).

En `config.psd1` usas `downloads.base` para centralizar la URL de todos los binarios estáticos.

## Notas importantes

- Todo es idempotente.
- NSSM y Nginx se pueden habilitar de forma independiente.
- Git = fácil rollback.
