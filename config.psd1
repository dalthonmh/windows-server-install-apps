@{
    server = @{
        name  = "WEB-PROD-01"
        drive = "D:"
    }

    nginx = @{
        enabled = $true
        version = "1.30.3"
        url     = "https://dalthonmh.com/bin/nginx-1.30.3.zip"

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
        }
    }
}
