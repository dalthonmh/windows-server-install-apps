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
            startup     = "Automatic"
            useNssm     = $true
        }
    }

    php = @{
        enabled = $true
        version = "8.2.31"

        paths = @{
            install = "D:\apps\php\8.2.31"
        }
    }

    apache = @{
        enabled = $true
        version = "2.4.68"

        paths = @{
            install = "D:\apps\apache\2.4.68"
            config  = "D:\config\apache"
            data    = "D:\data\apache"
            logs    = "D:\logs\apache"
        }

        port = 81

        service = @{
            name        = "Apache"
            displayName = "Apache HTTP Server"
            startup     = "Automatic"
            useNssm     = $true
        }
    }

    composer = @{
        enabled = $true
        version = "2.10.2"

        paths = @{
            install = "D:\apps\composer"
        }
    }
}
