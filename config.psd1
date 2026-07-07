# Configuracion
# Author: DalthonMH (dalthonmh@gmail.com)
# Ultima actualizacion: 2026-07-04
# Formato recomendado: config.psd1 (PowerShell Data File)

@{
    server = @{
        name  = "WEB-PROD-01"
        drive = "D:"
    }

    downloads = @{
        base = "https://dalthonmh.com/bin"
    }

    nssm = @{
        enabled = $true
        version = "2.24"

        paths = @{
            install = "tools\nssm"
        }
    }

    nginx = @{
        enabled = $true
        version = "1.30.3"

        paths = @{
            # Config ahora vive dentro del propio nginx (conf/nginx.conf + conf/sites-enabled)
            # No se usa carpeta externa D:\config\nginx
            install = "tools\nginx\1.30.3"
            logs    = "tools\logs\nginx"
        }

        port = 80

        service = @{
            name        = "nginx"
            displayName = "Nginx Web Server"
            startup     = "Automatic"
            useNssm     = $true
        }
    }

    php = @{
        enabled = $true
        version = "8.2.31"

        paths = @{
            install = "tools\php\8.2.31"
        }
    }

    apache = @{
        enabled = $true
        version = "2.4.68"

        paths = @{
            install = "tools\apache\2.4.68"
            logs    = "tools\logs\apache"
        }

        port = 81

        service = @{
            name        = "apache"
            displayName = "Apache HTTP Server"
            startup     = "Automatic"
            useNssm     = $true
        }
    }

    composer = @{
        enabled = $true
        version = "2.10.2"

        paths = @{
            install = "tools\composer"
        }
    }

    neovim = @{
        enabled = $true
        version = "0.12.3"

        paths = @{
            install = "tools\neovim\0.12.3"
        }
    }
}
