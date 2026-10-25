# Flexile one-line installer

Installs the [Flexile](https://flexile.io) panel for Adobe After Effects with one command.

macOS (Terminal):

```bash
curl -fsSL https://flexile.io/install.sh | bash
```

Windows (PowerShell):

```powershell
irm https://flexile.io/install.ps1 | iex
```

## What the scripts do

1. Read the latest release from `https://api.flexile.io/api/product/latest/flexile` (version and SHA-256).
2. Download `https://api.flexile.io/api/product/file/flexile/<version>`. The file is the signed ZXP (self-signed, `META-INF/signatures.xml` kept), so CEP loads it without debug mode.
3. Stop if the release has no checksum or the download does not match it. Nothing is changed in that case.
4. Unpack next to the final folder, then remove earlier Flexile installs and move the new one into place:
   - macOS: `~/Library/Application Support/Adobe/CEP/extensions/com.flexile.bc.io`
   - Windows: `%APPDATA%\Adobe\CEP\extensions\com.flexile.bc.io`

   Earlier installs are found by bundle id `com.flexile.bc.io` in `CSXS/manifest.xml`, whatever the folder is called. Other extensions are never touched. A link or junction (a developer build) is removed as a link; its target stays.
5. Warn if a copy for all users exists in the machine-wide CEP folder (`/Library/...` or `Program Files`), which needs admin rights to remove.
6. Say to restart After Effects if it is running. The scripts never close it.

No sudo or administrator rights are needed. The native Flexile Events plugin is not installed here; the panel offers it after the first launch.

## Telemetry

Each run sends one anonymous event to Flexile's PostHog project (EU): `install_script_completed` or `install_script_failed` with `os`, `version`, `error_code` and `script_version`. The id is random per run, no person profile is created and GeoIP is off. Set `FLEXILE_NO_TELEMETRY=1` to send nothing.

Error codes: `unsupported_os`, `missing_tool`, `metadata_failed`, `checksum_missing`, `download_failed`, `checksum_mismatch`, `unzip_failed`, `install_failed`, `unexpected` (Windows only).

## Tests

```bash
python3 tests/test_install.py
```

The tests run the real one-liners against a local fake of the release API and PostHog, with `HOME` / `APPDATA` in a temporary folder. They cover a fresh install, reinstalling over old and renamed versions (an unrelated extension and a linked developer build must survive), checksum mismatch, missing checksum, a failed download, the API being down, the machine-wide warning, and the telemetry opt-out. CI runs them on `macos-latest` (bash 3.2) and `windows-latest` (Windows PowerShell 5.1 and PowerShell 7), plus shellcheck and PSScriptAnalyzer.

## How flexile.io serves them

The website (`flexilehq/flexile-payload`) copies `install.sh` and `install.ps1` into `public/` and serves them as `text/plain; charset=utf-8` through `public/_headers`. Change the scripts here, then sync them to the website.
