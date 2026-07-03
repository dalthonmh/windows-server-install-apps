# Windows Server Install

Instalador simple, declarativo e idempotente para Nginx (y otros servicios) en Windows Server.

## Ejecutar (4 pasos)

> **Importante**: Funciona en PowerShell 5.1 (el que viene por defecto en Windows Server) y PowerShell 7.

1. En el servidor Windows (PowerShell como Administrador):

```powershell
Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
```

2. Clona o copia este repo:

```powershell
git clone https://github.com/dalthonmh/windows-server-install-apps.git C:\deploy\install-apps
cd C:\deploy\install-apps
```

3. Edita `config.json` (solo este archivo):

- Cambia `server.name`
- Ajusta `nginx.url` si usas tu dominio
- Cambia puerto o paths si quieres

4. Ejecuta:

```powershell
.\deploy.ps1
```

Eso es todo. El script es **idempotente**: puedes correrlo muchas veces. Solo hace lo necesario.

## Validar

```powershell
.\validate.ps1
```

O abre `http://ip-de-servidor-windows` en el navegador.

## Agregar un nuevo servicio (fácil)

1. Agrega el bloque en `config.json`:

   ```json
   "apache": {
     "enabled": true,
     "version": "...",
     "url": "https://...",
     "port": 8080,
     "paths": { ... },
     "service": { "name": "Apache", "displayName": "Apache" }
   }
   ```

2. Crea carpeta `components/apache/`

3. Copia los dos archivos de `components/nginx/` y renómbralos:
   - `apache.conf` (edita la plantilla)
   - `apache.ps1` (edita la lógica)

4. En `apache.ps1` cambia el nombre de las funciones:
   - `Install-ApacheComponent`
   - `Test-ApacheComponent`

¡Listo! `deploy.ps1` lo detecta automáticamente.

## Estructura (mínima)

```
.
├── README.md
├── config.json          # ← Edita solo esto
├── deploy.ps1           # ← Ejecuta esto
├── validate.ps1
├── .gitignore
└── components/
    └── nginx/
        ├── nginx.conf   # Plantilla
        └── nginx.ps1    # Lógica del componente
```

## Paths en el servidor (separación clara)

- App: `D:\apps\nginx\1.30.3`
- Config:`D:\config\nginx`
- Data: `D:\data\nginx`
- Logs: `D:\logs\nginx`

## Notas importantes

- Usa tu propio dominio para los zips (`https://dalthonmh.com/bin/...`)
- NSSM se descarga automáticamente si lo necesitas (o ponlo manualmente)
- Todo queda registrado en `D:\logs\deployment\`
- Git = historial y rollback fácil

Listo. Edita `config.json` → corre `deploy.ps1`.
