# Flexile for After Effects: one-line installer for Windows (PowerShell 5.1 or 7).
#
#   irm https://flexile.io/install.ps1 | iex
#
# Downloads the latest signed Flexile panel, checks its SHA-256, and installs it into your own
# Adobe CEP extensions folder (%APPDATA%\Adobe\CEP\extensions). No administrator rights.
# Only earlier Flexile installs in that folder are removed; other extensions are left alone.
#
# Settings (environment variables):
#   FLEXILE_NO_TELEMETRY=1   do not send the anonymous install_script_completed/failed event
#   FLEXILE_API_BASE         release API (default https://api.flexile.io), used by the tests
#   FLEXILE_TELEMETRY_URL    PostHog capture URL, used by the tests
#   FLEXILE_SYSTEM_EXTENSIONS_DIR  machine-wide CEP folder to check, used by the tests
#   FLEXILE_DEBUG=1          print the full error when something unexpected fails
#
# This file is plain ASCII on purpose (Windows PowerShell 5.1 may read it in the wrong encoding).
# It runs in a script block and never calls exit: `irm | iex` runs inside the user's own window.

& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue' # the progress bar makes Invoke-WebRequest many times slower on 5.1

    $scriptVersion = '1'
    $bundleId = 'com.flexile.bc.io'
    $apiBase = if ($env:FLEXILE_API_BASE) { $env:FLEXILE_API_BASE } else { 'https://api.flexile.io' }
    $telemetryUrl = if ($env:FLEXILE_TELEMETRY_URL) { $env:FLEXILE_TELEMETRY_URL } else { 'https://thehogpost.flexile.io/i/v0/e/' }
    $posthogKey = 'phc_E81RwwweC6V073BFzfX5OOFxuh2XyLGRvI7zOXnK4ln'
    $helpUrl = 'https://flexile.io/blog/how-to-install-flexile#why-is-flexile-not-showing-in-after-effects'
    $extDir = Join-Path $env:APPDATA 'Adobe\CEP\extensions'
    $systemDirs = if ($env:FLEXILE_SYSTEM_EXTENSIONS_DIR) { @($env:FLEXILE_SYSTEM_EXTENSIONS_DIR) } else {
        @("${env:ProgramFiles(x86)}\Common Files\Adobe\CEP\extensions", "$env:ProgramFiles\Common Files\Adobe\CEP\extensions")
    }

    # Symbols only where the console can draw them (Windows Terminal, VS Code); plain text elsewhere.
    $fancy = [bool]($env:WT_SESSION -or $env:TERM_PROGRAM)
    $ok = if ($fancy) { [string][char]0x2713 } else { 'OK' }
    $cross = if ($fancy) { [string][char]0x2717 } else { 'X' }
    $arrow = if ($fancy) { [string][char]0x2192 } else { '>' }
    $dots = if ($fancy) { [string][char]0x2026 } else { '...' }
    $sparkles = if ($fancy) { [char]::ConvertFromUtf32(0x2728) + ' ' } else { '' }
    $party = if ($fancy) { [char]::ConvertFromUtf32(0x1F389) + ' ' } else { '' }

    $version = 'unknown'
    $tmp = $null

    function Send-InstallEvent([string]$name, [string]$errorCode, [string]$errorDetail = '') {
        if ($env:FLEXILE_NO_TELEMETRY) { return }
        try {
            $body = @{
                api_key     = $posthogKey
                event       = $name
                distinct_id = 'install-' + [guid]::NewGuid().ToString()
                properties  = @{
                    os = 'windows'; version = $version; error_code = $errorCode; error_detail = $errorDetail; script_version = $scriptVersion
                    '$process_person_profile' = $false; '$geoip_disable' = $true
                }
            } | ConvertTo-Json -Depth 4 -Compress
            Invoke-RestMethod -Uri $telemetryUrl -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 5 -UseBasicParsing | Out-Null
        } catch { }
    }

    # Every failure ends here as "FLEXILE|code|message", so the user sees one plain sentence.
    function Stop-Install([string]$code, [string]$message) { throw "FLEXILE|$code|$message" }

    # Flexile folders: the bundle id in CSXS\manifest.xml, so renamed folders (com.flexile.bc.io-0_18_0,
    # flexile_0_17_0) are found and nothing else is touched.
    function Test-Flexile([string]$path) {
        $manifest = Join-Path $path 'CSXS\manifest.xml'
        (Test-Path -LiteralPath $manifest) -and
            [bool](Select-String -LiteralPath $manifest -Pattern "ExtensionBundleId=`"$bundleId`"" -SimpleMatch:$false -Quiet)
    }

    # A junction or symbolic link (a developer build): delete the link only, never what it points to.
    function Remove-Folder([string]$path) {
        $item = Get-Item -LiteralPath $path -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            [IO.Directory]::Delete($path)
        } else {
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }

    $detail = ''
    try {
        Write-Host "${sparkles}Installing Flexile for After Effects$dots"

        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        } catch { }

        try {
            $meta = Invoke-RestMethod -Uri "$apiBase/api/product/latest/flexile" -TimeoutSec 30 -UseBasicParsing
        } catch {
            Stop-Install 'metadata_failed' "Couldn't reach flexile.io. Check your internet connection and try again."
        }
        if (-not $meta.version) { Stop-Install 'metadata_failed' 'flexile.io sent an unexpected answer. Try again in a few minutes.' }
        $version = [string]$meta.version
        $sha256 = [string]$meta.sha256
        if ($sha256 -notmatch '^[0-9a-f]{64}$') {
            Stop-Install 'checksum_missing' "This Flexile release has no checksum yet, so it can't be verified. Try again later or download it from flexile.io."
        }

        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('flexile-install-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $tmp | Out-Null
        $zip = Join-Path $tmp 'flexile.zip'
        try {
            Invoke-WebRequest -Uri "$apiBase/api/product/file/flexile/$($version)" -OutFile $zip -TimeoutSec 900 -UseBasicParsing
        } catch {
            Stop-Install 'download_failed' "The download didn't finish. Check your internet connection and try again."
        }
        if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sha256) {
            Stop-Install 'checksum_mismatch' 'The download is damaged (checksum mismatch), so nothing was installed. Please try again.'
        }
        Write-Host "  $ok " -ForegroundColor Green -NoNewline
        Write-Host "Downloaded Flexile $($version)"

        try {
            New-Item -ItemType Directory -Path $extDir -Force | Out-Null
        } catch {
            Stop-Install 'install_failed' "Couldn't create your Adobe extensions folder."
        }
        # Unpack next to the final folder, then swap: an interrupted install never leaves half a panel.
        $staged = Join-Path $extDir ".flexile-install-$PID"
        if (Test-Path -LiteralPath $staged) { Remove-Folder $staged }
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [IO.Compression.ZipFile]::ExtractToDirectory($zip, $staged)
        } catch {
            if (Test-Path -LiteralPath $staged) { Remove-Folder $staged }
            Stop-Install 'unzip_failed' "Couldn't unpack Flexile. Check that your disk has 500 MB free and try again."
        }
        if (-not (Test-Flexile $staged)) {
            Remove-Folder $staged
            Stop-Install 'unzip_failed' 'The download is not a Flexile panel. Please try again.'
        }

        try {
            Get-ChildItem -LiteralPath $extDir -Directory -Force |
                Where-Object { $_.FullName -ne $staged -and (Test-Flexile $_.FullName) } |
                ForEach-Object { Remove-Folder $_.FullName }
        } catch {
            Remove-Folder $staged
            Stop-Install 'install_failed' "Couldn't remove the previous Flexile version. Quit After Effects and try again."
        }
        try {
            Move-Item -LiteralPath $staged -Destination (Join-Path $extDir $bundleId)
        } catch {
            Remove-Folder $staged
            Stop-Install 'install_failed' "Couldn't move Flexile into your Adobe extensions folder."
        }
        Write-Host "  $ok " -ForegroundColor Green -NoNewline
        Write-Host 'Installed'

        foreach ($dir in $systemDirs) {
            if (-not (Test-Path -LiteralPath $dir)) { continue }
            $old = Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue |
                Where-Object { Test-Flexile $_.FullName } | Select-Object -First 1
            if ($old) {
                Write-Host '  ! ' -ForegroundColor Yellow -NoNewline
                Write-Host "An older copy for all users is in $($old.FullName). Remove it if Flexile does not update."
                break
            }
        }

        if (Get-Process -Name 'AfterFX' -ErrorAction SilentlyContinue) {
            Write-Host "${party}Done! Restart After Effects, then open Window $arrow Extensions $arrow Flexile"
        } else {
            Write-Host "${party}Done! Open After Effects, then Window $arrow Extensions $arrow Flexile"
        }
        Send-InstallEvent 'install_script_completed' ''
    } catch {
        $parts = "$($_.Exception.Message)".Split('|')
        if ($parts.Count -ge 3 -and $parts[0] -eq 'FLEXILE') {
            $code = $parts[1]; $message = $parts[2]
        } else {
            $code = 'unexpected'; $message = 'Something went wrong while installing Flexile. Please try again.'
            # Exception type and script line only: no paths or user names leave the machine.
            $detail = '{0} at line {1}' -f $_.Exception.GetType().Name, $_.InvocationInfo.ScriptLineNumber
            if ($env:FLEXILE_DEBUG) { Write-Host ($_ | Out-String); Write-Host $_.InvocationInfo.PositionMessage }
        }
        Write-Host "$cross $message" -ForegroundColor Red
        Write-Host "  Help: $helpUrl"
        Send-InstallEvent 'install_script_failed' $code $detail
    } finally {
        if ($tmp -and (Test-Path -LiteralPath $tmp)) {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
