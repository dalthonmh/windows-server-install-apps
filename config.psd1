@{
    server = @{
        name  = "WEB-PROD-01"
        drive = "D:"
    }

    # Base comun para todos los binarios estaticos (nginx, nssm, etc.)
    downloads = @{
        base = "https://dalthonmh.com/bin"
    }

    # NSSM separado (recomendado para usar como service wrapper)
    nssm = @{
        enabled = $true
        version = "2.24"
        # url se construye como: $downloads.base + "/nssm-$version.zip"
    }

    nginx = @{
        enabled = $true
        version = "1.30.3"
        # url opcional, se construye si no se provee: $downloads.base + "/nginx-$version.zip"

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
}
