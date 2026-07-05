# Shared helper for efficient, cached downloads.
# Downloads a file ONLY if it doesn't already exist in the cache directory.
# This guarantees that network downloads happen at most once per file/version.
# Components only call Get-CachedDownload and then decide when to extract.

function Get-CachedDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$CacheDir,

        [Parameter(Mandatory = $true)]
        [string]$FileName,

        [string]$Label   # Optional, e.g. "[nginx]" to prefix the message
    )

    New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null

    $cachedFile = Join-Path $CacheDir $FileName

    if (-not (Test-Path $cachedFile)) {
        $msg = if ($Label) { "$Label Downloading $FileName..." } else { "Downloading $FileName..." }
        Write-Host $msg -ForegroundColor Cyan

        # Disable progress for faster downloads on servers
        $oldProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri $Url -OutFile $cachedFile -UseBasicParsing
        } finally {
            $ProgressPreference = $oldProgress
        }
    }

    # Note: We no longer auto-remove on validation here.
    # If a cached zip is bad, the extract in the component will catch it and remove.

    return $cachedFile
}
