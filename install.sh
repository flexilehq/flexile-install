#!/usr/bin/env bash
# Flexile for After Effects: one-line installer for macOS.
#
#   curl -fsSL https://flexile.io/install.sh | bash
#
# Downloads the latest signed Flexile panel, checks its SHA-256, and installs it into your own
# Adobe CEP extensions folder (~/Library/Application Support/Adobe/CEP/extensions). No sudo.
# Only earlier Flexile installs in that folder are removed; other extensions are left alone.
#
# Settings (environment variables):
#   FLEXILE_NO_TELEMETRY=1   do not send the anonymous install_script_completed/failed event
#   FLEXILE_API_BASE         release API (default https://api.flexile.io), used by the tests
#   FLEXILE_TELEMETRY_URL    PostHog capture URL, used by the tests
#   FLEXILE_SYSTEM_EXTENSIONS_DIR  machine-wide CEP folder to check, used by the tests

# Everything runs inside main, so a download cut off half way never runs half a script.
main() {
  set -u

  local script_version="1"
  local bundle_id="com.flexile.bc.io"
  local api_base="${FLEXILE_API_BASE:-https://api.flexile.io}"
  local telemetry_url="${FLEXILE_TELEMETRY_URL:-https://thehogpost.flexile.io/i/v0/e/}"
  local posthog_key="phc_E81RwwweC6V073BFzfX5OOFxuh2XyLGRvI7zOXnK4ln"
  local help_url="https://flexile.io/blog/how-to-install-flexile#why-is-flexile-not-showing-in-after-effects"
  local ext_dir="$HOME/Library/Application Support/Adobe/CEP/extensions"
  local system_dir="${FLEXILE_SYSTEM_EXTENSIONS_DIR:-/Library/Application Support/Adobe/CEP/extensions}"
  local version="" tmp=""

  local green="" red="" yellow="" bold="" reset=""
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
    green=$'\033[32m' red=$'\033[31m' yellow=$'\033[33m' bold=$'\033[1m' reset=$'\033[0m'
  fi

  send_event() { # event error_code
    [ -n "${FLEXILE_NO_TELEMETRY:-}" ] && return 0
    local id
    id="$(uuidgen 2>/dev/null || echo "$RANDOM$RANDOM$RANDOM")"
    curl -fsS -m 5 -o /dev/null -H 'Content-Type: application/json' -X POST "$telemetry_url" \
      --data "{\"api_key\":\"$posthog_key\",\"event\":\"$1\",\"distinct_id\":\"install-$id\",\"properties\":{\"os\":\"macos\",\"version\":\"${version:-unknown}\",\"error_code\":\"$2\",\"script_version\":\"$script_version\",\"\$process_person_profile\":false,\"\$geoip_disable\":true}}" \
      >/dev/null 2>&1 || true
  }

  fail() { # error_code message
    printf '%s✗ %s%s\n' "$red" "$2" "$reset"
    printf '  Help: %s\n' "$help_url"
    send_event install_script_failed "$1"
    [ -n "$tmp" ] && rm -rf "$tmp"
    exit 1
  }

  # Flexile folders: the bundle id in CSXS/manifest.xml, so a renamed folder (com.flexile.bc.io-0_18_0,
  # flexile_0_17_0) is found and nothing else is touched.
  is_flexile() {
    local manifest="$1/CSXS/manifest.xml"
    [ -f "$manifest" ] && grep -Eq "ExtensionBundleId=\"$bundle_id\"" "$manifest"
  }

  printf '%s✨ Installing Flexile for After Effects…%s\n' "$bold" "$reset"

  [ "$(uname -s)" = "Darwin" ] || fail unsupported_os "This installer is for macOS. On Windows, run the PowerShell command from flexile.io/dashboard/download."
  for tool in curl unzip shasum; do
    command -v "$tool" >/dev/null 2>&1 || fail missing_tool "Your Mac is missing the $tool command, so Flexile can't be installed this way."
  done

  local meta
  meta="$(curl -fsSL -m 30 "$api_base/api/product/latest/flexile")" ||
    fail metadata_failed "Couldn't reach flexile.io. Check your internet connection and try again."
  version="$(printf '%s' "$meta" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  local sha256
  sha256="$(printf '%s' "$meta" | sed -n 's/.*"sha256"[[:space:]]*:[[:space:]]*"\([0-9a-f]\{64\}\)".*/\1/p')"
  [ -n "$version" ] || fail metadata_failed "flexile.io sent an unexpected answer. Try again in a few minutes."
  [ -n "$sha256" ] || fail checksum_missing "This Flexile release has no checksum yet, so it can't be verified. Try again later or download it from flexile.io."

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/flexile-install.XXXXXX")" || fail install_failed "Couldn't create a temporary folder."
  curl -fsSL -m 900 -o "$tmp/flexile.zip" "$api_base/api/product/file/flexile/$version" ||
    fail download_failed "The download didn't finish. Check your internet connection and try again."
  [ "$(shasum -a 256 "$tmp/flexile.zip" | cut -d' ' -f1)" = "$sha256" ] ||
    fail checksum_mismatch "The download is damaged (checksum mismatch), so nothing was installed. Please try again."
  printf '  %s✓%s Downloaded Flexile %s\n' "$green" "$reset" "$version"

  mkdir -p "$ext_dir" || fail install_failed "Couldn't create your Adobe extensions folder."
  # Unpack next to the final folder, then swap: an interrupted install never leaves half a panel.
  local staged="$ext_dir/.flexile-install-$$"
  rm -rf "$staged"
  unzip -q "$tmp/flexile.zip" -d "$staged" 2>/dev/null && is_flexile "$staged" ||
    { rm -rf "$staged"; fail unzip_failed "Couldn't unpack Flexile. Check that your disk has 500 MB free and try again."; }

  local entry
  for entry in "$ext_dir"/* "$ext_dir"/.[!.]*; do
    [ "$entry" = "$staged" ] && continue
    { [ -e "$entry" ] || [ -L "$entry" ]; } || continue
    is_flexile "$entry" || continue
    if [ -L "$entry" ]; then
      rm -f "$entry" # a link (a developer build): remove the link, never what it points to
    else
      rm -rf "$entry"
    fi || { rm -rf "$staged"; fail install_failed "Couldn't remove the previous Flexile version. Quit After Effects and try again."; }
  done
  mv "$staged" "$ext_dir/$bundle_id" ||
    { rm -rf "$staged"; fail install_failed "Couldn't move Flexile into your Adobe extensions folder."; }
  rm -rf "$tmp"
  tmp=""
  printf '  %s✓%s Installed\n' "$green" "$reset"

  for entry in "$system_dir"/*; do
    if [ -e "$entry" ] && is_flexile "$entry"; then
      printf '  %s!%s An older copy for all users is in %s. Remove it if Flexile does not update.\n' "$yellow" "$reset" "$entry"
      break
    fi
  done

  if pgrep -xq "After Effects" 2>/dev/null || pgrep -fq "Adobe After Effects.*\.app/Contents/MacOS" 2>/dev/null; then
    printf '🎉 Done! Restart After Effects, then open Window → Extensions → Flexile\n'
  else
    printf '🎉 Done! Open After Effects, then Window → Extensions → Flexile\n'
  fi
  send_event install_script_completed ""
}

main "$@"
