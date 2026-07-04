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
git clone https://github.com/dalthonmh/windows-server-install-apps.git C:\deploy\install-apps
cd C:\deploy\install-apps
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
            name        = "Nginx"
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

## Agregar un nuevo servicio (fácil)

1. Agrega el bloque en `config.psd1` (usa `downloads.base` cuando sea posible):

   ```powershell
   apache = @{
       enabled = $true
       version = "2.4"
       port    = 8080
       paths   = @{ ... }
       service = @{ name = "Apache"; displayName = "Apache" }
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

## Estructura (modular)

```
.
├── README.md
├── config.psd1
├── deploy.ps1
├── validate.ps1
└── components/
    ├── nssm/
    │   └── nssm.ps1          # Lógica de NSSM + PATH global
    └── nginx/
        ├── nginx.conf        # Plantilla de configuración
        └── nginx.ps1         # Lógica de Nginx
```

## Paths en el servidor (separación clara)

- App: `D:\apps\nginx\1.30.3`
- Config: `D:\config\nginx`
- Data: `D:\data\nginx`
- Logs: `D:\logs\nginx`

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
