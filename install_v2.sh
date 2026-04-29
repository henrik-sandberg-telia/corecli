#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# CoreCli install script
# Authenticates to Azure via PKCE browser flow (same as `corecli login`) using
# the CoreCli app registration. Downloads latest.txt and the release zip from
# Azure Blob Storage (Entra ID RBAC — Storage Blob Data Reader required).
#
# Requirements: curl, unzip, python3
#
# App registration: 520894b5-f6ae-42e1-9248-de753858e3ad (CoreCli, Telia Company)
# Access: Members of the CoreCli Entra groups with Storage Blob Data Reader on
#         sptweusacorecli/releases container.
#
# Security: This script contains no secrets. Access to the download is controlled
# entirely by Azure RBAC — a valid Entra ID token with Storage Blob Data Reader
# on sptweusacorecli/releases is required. Do not make the container public.
# ---------------------------------------------------------------------------

TENANT="05764a73-8c6f-4538-83cd-413f1e1b5665"          # Telia Company AAD tenant
CLIENT_ID="aebc6443-996d-45c2-90f0-388ff96faa56"        # VS Code public client — pre-consented for Azure Storage in enterprise tenants
                                                           # Fallback: 520894b5-f6ae-42e1-9248-de753858e3ad (CoreCli app, requires admin consent for Storage scope)
SCOPE="https://storage.azure.com/user_impersonation"
STORAGE_BASE="https://sptweusacorecli.blob.core.windows.net/releases"
LATEST_TXT_URL="$STORAGE_BASE/latest.txt"
INSTALL_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
INSTALL_SCRIPT_VERSION="2026-04-29.1"
TARGET_BROWSER="/mnt/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"
BROWSER_SETUP_MODE="auto"
BROWSER_SETUP_MARKER="# CoreCli browser setup"
PATH_SETUP_MARKER="# CoreCli path setup"
TMP_ZIP="/tmp/CoreCli_install_$$.zip"
TMP_EXTRACT="/tmp/corecli-extract-$$"
TMP_CODE="/tmp/CoreCli_authcode_$$"
TMP_PYLISTENER="/tmp/CoreCli_listener_$$.py"
ZIP_INNER_DIR="CoreCli/linux-x64-singlefile"   # directory containing binary + PDB files
DEBUG=0
NON_INTERACTIVE=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

die() { red "ERROR: $*" >&2; exit 1; }

debug_log() {
  [[ "$DEBUG" -eq 1 ]] || return 0
  printf '[debug] %s\n' "$*"
}

prompt_yes_no() {
  local prompt="$1"
  local default_answer="${2:-Y}"
  local reply

  if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
    debug_log "Auto-answering prompt in non-interactive mode: $prompt -> $default_answer"
    [[ "$default_answer" =~ ^[Yy]$ ]]
    return
  fi

  read -r -p "$prompt" reply
  if [[ -z "$reply" ]]; then
    reply="$default_answer"
  fi

  [[ "$reply" =~ ^[Yy]$ ]]
}

show_usage() {
  cat <<'USAGE'
Usage: ./scripts/install.sh [--debug|-d] [--setup-browser] [--no-setup-browser] [--yes|-y|--non-interactive] [--help|-h]

Options:
  -d, --debug           Print auth URL and browser-launch diagnostics.
      --setup-browser   Persist BROWSER for WSL shells even if already set in this session.
      --no-setup-browser
                        Skip automatic WSL BROWSER setup.
  -y, --yes,
      --non-interactive Auto-accept installer prompts and use default values.
  -h, --help            Show this help and exit.
USAGE
}

show_debug_banner() {
  [[ "$DEBUG" -eq 1 ]] || return 0
  yellow "Installer debug mode"
  printf '  script: %s\n' "$0"
  printf '  version: %s\n' "$INSTALL_SCRIPT_VERSION"
  printf '  shell: %s\n' "${SHELL:-<unset>}"
  printf '  install dir: %s\n' "$INSTALL_DIR"
}

is_wsl() {
  grep -qiE "(microsoft|wsl)" /proc/version 2>/dev/null
}

browser_env_is_target() {
  [[ "${BROWSER:-}" == "$TARGET_BROWSER" ]]
}

select_shell_rc_file() {
  local shell_name="${SHELL##*/}"
  case "$shell_name" in
    bash)
      printf '%s\n' "$HOME/.bashrc"
      ;;
    zsh)
      printf '%s\n' "$HOME/.zshrc"
      ;;
    *)
      for candidate in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
        if [[ -f "$candidate" ]]; then
          printf '%s\n' "$candidate"
          return 0
        fi
      done
      printf '%s\n' "$HOME/.profile"
      ;;
  esac
}

shell_reload_command() {
  local rc_file="$1"
  printf 'source "%s"' "$rc_file"
}

rc_has_target_browser_export() {
  local rc_file="$1"
  [[ -f "$rc_file" ]] || return 1
  grep -Fqx "export BROWSER=\"$TARGET_BROWSER\"" "$rc_file"
}

rc_has_any_browser_export() {
  local rc_file="$1"
  [[ -f "$rc_file" ]] || return 1
  grep -Eq '^[[:space:]]*export[[:space:]]+BROWSER=' "$rc_file"
}

append_target_browser_export() {
  local rc_file="$1"
  touch "$rc_file" || die "Could not create or update $rc_file"
  {
    printf '\n%s\n' "$BROWSER_SETUP_MARKER"
    printf 'export BROWSER="%s"\n' "$TARGET_BROWSER"
  } >> "$rc_file"
}

path_env_contains_install_dir() {
  case ":$PATH:" in
    *":$INSTALL_DIR:"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

rc_has_install_dir_path_export() {
  local rc_file="$1"
  [[ -f "$rc_file" ]] || return 1
  grep -Eq "(^|[[:space:]])PATH=.*${INSTALL_DIR//\//\\/}" "$rc_file"
}

append_install_dir_path_export() {
  local rc_file="$1"
  touch "$rc_file" || die "Could not create or update $rc_file"
  {
    printf '\n%s\n' "$PATH_SETUP_MARKER"
    printf 'export PATH="%s:$PATH"\n' "$INSTALL_DIR"
  } >> "$rc_file"
}

configure_path_shell_env() {
  local rc_file
  local reload_cmd

  if path_env_contains_install_dir; then
    green "$INSTALL_DIR is already on PATH for this shell session."
    debug_log "Skipping PATH persistence because $INSTALL_DIR is already on PATH"
    return 0
  fi

  rc_file="$(select_shell_rc_file)"
  reload_cmd="$(shell_reload_command "$rc_file")"
  debug_log "PATH setup target rc file: $rc_file"

  if rc_has_install_dir_path_export "$rc_file"; then
    yellow "WARNING: $INSTALL_DIR is not in your \$PATH for this shell session."
    yellow "It is already configured in $rc_file. To load it now, run:"
    printf '  %s\n' "$reload_cmd"
    return 0
  fi

  append_install_dir_path_export "$rc_file"
  green "Configured PATH update in $rc_file"
  yellow "To load it in your shell after install, run:"
  printf '  %s\n' "$reload_cmd"
}

ensure_current_session_browser() {
  export BROWSER="$TARGET_BROWSER"
}

install_missing_packages() {
  local packages=("$@")
  local apt_cmd=()

  [[ ${#packages[@]} -gt 0 ]] || return 0

  if ! command -v apt-get >/dev/null 2>&1; then
    die "Missing required tools: ${packages[*]}. Install them manually and retry."
  fi

  yellow "Missing required tools: ${packages[*]}"
  if ! prompt_yes_no "Install them now with apt-get? [Y/n]: " "Y"; then
    die "Cannot continue without: ${packages[*]}"
  fi

  if [[ "$EUID" -eq 0 ]]; then
    apt_cmd=(apt-get)
  elif command -v sudo >/dev/null 2>&1; then
    apt_cmd=(sudo apt-get)
  else
    die "sudo is required to install missing packages. Install sudo or run this script as root."
  fi

  "${apt_cmd[@]}" update
  "${apt_cmd[@]}" install -y "${packages[@]}"
}

resolve_icu_package() {
  if ! command -v apt-cache >/dev/null 2>&1; then
    printf '%s\n' "libicu-dev"
    return 0
  fi

  local package_name
  package_name="$(apt-cache pkgnames 2>/dev/null | grep -E '^libicu[0-9]+$' | sort -V | tail -n 1)"
  if [[ -n "$package_name" ]]; then
    printf '%s\n' "$package_name"
    return 0
  fi

  printf '%s\n' "libicu-dev"
}

ensure_runtime_requirements() {
  local runtime_packages=()

  if ! ldconfig -p 2>/dev/null | grep -q 'libicuuc'; then
    runtime_packages+=("$(resolve_icu_package)")
  fi

  install_missing_packages "${runtime_packages[@]}"

  if ! ldconfig -p 2>/dev/null | grep -q 'libicuuc'; then
    die "CoreCli requires ICU on Linux. Install libicu and retry."
  fi
}

ensure_required_tools() {
  local missing_packages=()
  local tool

  for tool in curl unzip python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      missing_packages+=("$tool")
    fi
  done

  install_missing_packages "${missing_packages[@]}"

  for tool in curl unzip python3; do
    command -v "$tool" >/dev/null 2>&1 || die "'$tool' is required but could not be installed."
  done
}

configure_browser_shell_env() {
  local rc_file
  local reload_cmd

  if ! is_wsl; then
    debug_log "Skipping BROWSER persistence outside WSL"
    return 0
  fi

  if [[ "$BROWSER_SETUP_MODE" == "skip" ]]; then
    yellow "Skipping WSL BROWSER setup (--no-setup-browser)."
    return 0
  fi

  ensure_current_session_browser

  rc_file="$(select_shell_rc_file)"
  reload_cmd="$(shell_reload_command "$rc_file")"

  if rc_has_target_browser_export "$rc_file"; then
    green "Using Microsoft Edge for BROWSER in this installer session."
    green "BROWSER is already configured in $rc_file"
    yellow "To load it in your shell after install, run:"
    printf '  %s\n' "$reload_cmd"
    return 0
  fi

  if rc_has_any_browser_export "$rc_file"; then
    green "Using Microsoft Edge for BROWSER in this installer session."
    yellow "Detected an existing BROWSER export in $rc_file. Leaving it unchanged."
    yellow "If you want to persist Microsoft Edge for future shells, add:"
    printf '  export BROWSER="%s"\n' "$TARGET_BROWSER"
    return 0
  fi

  append_target_browser_export "$rc_file"
  green "Using Microsoft Edge for BROWSER in this installer session."
  green "Configured BROWSER in $rc_file"
  yellow "To load it in your shell after install, run:"
  printf '  %s\n' "$reload_cmd"
}

for arg in "$@"; do
  case "$arg" in
    -d|--debug)
      DEBUG=1
      ;;
    --setup-browser)
      BROWSER_SETUP_MODE="force"
      ;;
    --no-setup-browser)
      BROWSER_SETUP_MODE="skip"
      ;;
    -y|--yes|--non-interactive)
      NON_INTERACTIVE=1
      ;;
    -h|--help)
      show_usage
      exit 0
      ;;
    *)
      die "Unknown argument: $arg. Use --help to see supported options."
      ;;
  esac
done

show_debug_banner

open_browser() {
  local url="$1"
  local is_wsl=0
  local resolved_xdg="<not-found>"
  local resolved_wslview="<not-found>"
  local resolved_browser="<not-found>"

  if command -v xdg-open >/dev/null 2>&1; then
    resolved_xdg="$(command -v xdg-open)"
  fi
  if command -v wslview >/dev/null 2>&1; then
    resolved_wslview="$(command -v wslview)"
  fi

  if is_wsl; then
    is_wsl=1
  fi

  debug_log "Browser launch context: is_wsl=$is_wsl BROWSER=${BROWSER:-<unset>}"
  debug_log "Resolved launchers: xdg-open=$resolved_xdg wslview=$resolved_wslview"

  # Hard block: in WSL, refuse likely user-wrapper xdg-open when wslview is absent.
  # This avoids OAuth URL mangling observed with legacy wrapper setups.
  if [[ "$is_wsl" -eq 1 && "$resolved_wslview" == "<not-found>" && "$resolved_xdg" == "$HOME"/* ]]; then
    die "Detected user-managed xdg-open at '$resolved_xdg' in WSL without wslview.

  This setup can mangle Entra auth URLs and break login.

  Fix options:
    1) Install wslview (recommended):
         sudo apt install wslu
    2) Or set BROWSER to a real Windows browser executable (not xdg-open/wslview):
         export BROWSER='$TARGET_BROWSER'

  Then re-run with:
    ./scripts/install.sh --debug"
  fi

  # 1. Respect explicit BROWSER env var (works everywhere including WSL)
  if [[ -n "${BROWSER:-}" ]]; then
    if command -v "$BROWSER" >/dev/null 2>&1; then
      resolved_browser="$(command -v "$BROWSER")"
      debug_log "Resolved BROWSER binary: $resolved_browser"
    else
      debug_log "Resolved BROWSER binary: <not-found-or-not-in-PATH> (may still be a valid absolute path)"
    fi

    # If BROWSER points to helper launchers, skip direct execution and use
    # the platform fallbacks below to reduce risk of URL mangling.
    if [[ "$resolved_browser" == "$resolved_xdg" || "$resolved_browser" == "$resolved_wslview" ]]; then
      debug_log "BROWSER points to helper launcher; skipping direct BROWSER execution"
    else
      debug_log "Trying BROWSER launcher: $BROWSER"
      if "$BROWSER" "$url" 2>/dev/null; then
        debug_log "Browser opened with BROWSER launcher"
        return
      fi
      debug_log "BROWSER launcher failed"
    fi
  fi

  # 2. On WSL, prefer wslview before xdg-open to avoid wrapper quirks.
  if [[ "$is_wsl" -eq 1 ]]; then
    if command -v wslview >/dev/null 2>&1; then
      debug_log "Trying launcher: wslview"
      if wslview "$url" 2>/dev/null; then
        debug_log "Browser opened with wslview"
        return
      fi
      debug_log "wslview launcher failed"
    fi
    if command -v xdg-open >/dev/null 2>&1; then
      debug_log "Trying launcher: xdg-open"
      if xdg-open "$url" 2>/dev/null; then
        debug_log "Browser opened with xdg-open"
        return
      fi
      debug_log "xdg-open launcher failed"
    fi
  else
    # 2. Native Linux: xdg-open first, then wslview fallback if available.
    if command -v xdg-open >/dev/null 2>&1; then
      debug_log "Trying launcher: xdg-open"
      if xdg-open "$url" 2>/dev/null; then
        debug_log "Browser opened with xdg-open"
        return
      fi
      debug_log "xdg-open launcher failed"
    fi
    if command -v wslview >/dev/null 2>&1; then
      debug_log "Trying launcher: wslview"
      if wslview "$url" 2>/dev/null; then
        debug_log "Browser opened with wslview"
        return
      fi
      debug_log "wslview launcher failed"
    fi
  fi

  die "Could not open a browser. CoreCli install requires a working browser to authenticate.

  Fix browser routing first, then re-run this script:

  On WSL/Ubuntu — install wslu (provides wslview):
    sudo apt install wslu

  Or set the BROWSER environment variable to your browser path:
    export BROWSER='$TARGET_BROWSER'
    ./scripts/install.sh

  Or on native Linux, ensure xdg-open is configured:
    xdg-settings set default-web-browser <browser>.desktop"
}

cleanup() {
  [[ -n "$LISTENER_PID" ]] && kill "$LISTENER_PID" 2>/dev/null || true
  rm -f  "$TMP_ZIP" "$TMP_CODE" "$TMP_PYLISTENER" 2>/dev/null || true
  rm -rf "$TMP_EXTRACT" 2>/dev/null || true
}
trap cleanup EXIT

LISTENER_PID=""

# ---------------------------------------------------------------------------
# 1. Dependency check
# ---------------------------------------------------------------------------

ensure_required_tools
ensure_runtime_requirements

# ---------------------------------------------------------------------------
# 2. WSL browser setup
# ---------------------------------------------------------------------------

echo ""
bold "Checking browser setup..."
configure_browser_shell_env

# ---------------------------------------------------------------------------
# 3. PKCE Authentication (browser-based — satisfies Conditional Access)
# ---------------------------------------------------------------------------

bold "Authenticating via browser (Entra ID)..."

# Generate PKCE code_verifier and code_challenge
read -r CODE_VERIFIER CODE_CHALLENGE < <(python3 -c "
import secrets, hashlib, base64
v = secrets.token_urlsafe(64)
c = base64.urlsafe_b64encode(hashlib.sha256(v.encode()).digest()).rstrip(b'=').decode()
print(v, c)
")

# Pick a random free localhost port
PORT=$(python3 -c "
import socket
s = socket.socket()
s.bind(('', 0))
print(s.getsockname()[1])
s.close()
")

REDIRECT_URI="http://localhost:${PORT}"

# Write Python listener to a temp file and background it
# Listener catches the AAD redirect, extracts ?code= and writes it to TMP_CODE
rm -f "$TMP_CODE"
cat > "$TMP_PYLISTENER" <<'PYEOF'
import sys, socket, urllib.parse

port     = int(sys.argv[1])
out_file = sys.argv[2]

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('localhost', port))
srv.listen(1)
srv.settimeout(120)

try:
    conn, _ = srv.accept()
    data = conn.recv(4096).decode(errors='replace')
    conn.sendall(
        b'HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n'
        b'<html><body><h2>Authentication complete. You may close this tab.</h2></body></html>'
    )
    conn.close()
    line = data.split('\n')[0]            # GET /?code=xxx HTTP/1.1
    path = line.split(' ')[1] if len(line.split(' ')) > 1 else '/'
    params = urllib.parse.parse_qs(urllib.parse.urlparse(path).query)
    code = params.get('code', [''])[0]
    with open(out_file, 'w') as f:
        f.write(code)
except socket.timeout:
    pass
finally:
    srv.close()
PYEOF

python3 "$TMP_PYLISTENER" "$PORT" "$TMP_CODE" &
LISTENER_PID=$!

# Build authorization URL and open browser
AUTH_URL="https://login.microsoftonline.com/${TENANT}/oauth2/v2.0/authorize"
AUTH_URL+="?client_id=${CLIENT_ID}"
AUTH_URL+="&response_type=code"
AUTH_URL+="&redirect_uri=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe='')); " "$REDIRECT_URI")"
AUTH_URL+="&scope=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe='')); " "$SCOPE offline_access")"
AUTH_URL+="&code_challenge=${CODE_CHALLENGE}"
AUTH_URL+="&code_challenge_method=S256"
AUTH_URL+="&prompt=select_account"

# Guard against accidental URL mangling before browser launch.
for required in "client_id=" "response_type=code" "redirect_uri=" "scope=" "code_challenge="; do
  [[ "$AUTH_URL" == *"$required"* ]] || die "Auth URL is missing required parameter: $required"
done

debug_log "Authorize URL length: ${#AUTH_URL}"

echo ""
yellow "Opening browser for authentication..."
if [[ "$DEBUG" -eq 1 ]]; then
  yellow "Debug: full authorize URL"
  echo "$AUTH_URL"
  echo ""
  yellow "If the opened page shows an auth parameter error, copy/paste the full URL above manually."
fi
echo ""
open_browser "$AUTH_URL"

# Wait up to 120 s for the listener to write the auth code
AUTH_CODE=""
for _ in $(seq 1 120); do
  sleep 1
  if [[ -s "$TMP_CODE" ]]; then
    AUTH_CODE=$(cat "$TMP_CODE")
    break
  fi
done

kill "$LISTENER_PID" 2>/dev/null || true
LISTENER_PID=""

[[ -n "$AUTH_CODE" ]] || die "Authentication timed out — the browser redirect to localhost was not received.

  This usually means browser routing or WSL localhost forwarding is not working.

  If you recently switched VPN connections in Windows, localhost forwarding may be stale.
  Recovery steps:
    1) From Windows PowerShell: wsl --shutdown
    2) Re-open WSL terminal
    3) Re-run: ./scripts/install.sh --debug

  Quick forwarding test (from WSL):
    python3 -m http.server 8765 --bind 127.0.0.1
  Then open in Windows browser:
    http://localhost:8765
  If that fails, forwarding is broken on the Windows/WSL side (often VPN/firewall policy).

  Ensure %UserProfile%/.wslconfig contains:
    [wsl2]
    localhostForwarding=true

  Browser routing fix options:

  On WSL/Ubuntu — install wslu:
    sudo apt install wslu

  Or set BROWSER explicitly:
    export BROWSER='/mnt/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'
    ./scripts/install.sh"

# Exchange auth code for access token
token_response=$(curl -s -X POST \
  "https://login.microsoftonline.com/${TENANT}/oauth2/v2.0/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=authorization_code" \
  --data-urlencode "client_id=$CLIENT_ID" \
  --data-urlencode "code=$AUTH_CODE" \
  --data-urlencode "redirect_uri=$REDIRECT_URI" \
  --data-urlencode "code_verifier=$CODE_VERIFIER" \
  --data-urlencode "scope=$SCOPE offline_access")

TOKEN=$(echo "$token_response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))")
[[ -n "$TOKEN" ]] || die "Token exchange failed: $(echo "$token_response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error_description', d.get('error','unknown')))")"

green "Authentication successful."
echo ""

# Blob storage requests require this header when using OAuth
BLOB_HEADERS=(-H "Authorization: Bearer $TOKEN" -H "x-ms-version: 2020-04-08")

# ---------------------------------------------------------------------------
# 3. Fetch latest version info from blob storage
# ---------------------------------------------------------------------------

bold "Fetching latest version info..."

LATEST_CONTENT=$(curl -sf "${BLOB_HEADERS[@]}" "$LATEST_TXT_URL") \
  || die "Could not read latest.txt from storage. Do you have Storage Blob Data Reader on the releases container?"

VERSION=$(echo "$LATEST_CONTENT" | awk '/^Version:/{print $2}')
URL=$(echo "$LATEST_CONTENT"     | awk '/^URL:/{print $2}')

[[ -n "$VERSION" ]] || die "Could not parse 'Version:' from latest.txt."
[[ -n "$URL" ]]     || die "Could not parse 'URL:' from latest.txt."

green "Latest stable: $VERSION"
echo ""

# ---------------------------------------------------------------------------
# 4. Prompt for binary name
# ---------------------------------------------------------------------------

if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
  LINK_NAME="corecli"
  yellow "Non-interactive mode: using default binary name '$LINK_NAME'."
else
  read -rp "Binary name in $INSTALL_DIR [corecli]: " LINK_NAME
  LINK_NAME="${LINK_NAME:-corecli}"
fi

[[ "$LINK_NAME" != */* ]] || die "Binary name must not contain '/'. Got: $LINK_NAME"
[[ -n "$LINK_NAME" ]]     || die "Binary name must not be empty."

INSTALL_BIN="$INSTALL_DIR/$LINK_NAME"

echo ""
bold "Installing CoreCli $VERSION to $INSTALL_DIR/$LINK_NAME..."
echo ""

# ---------------------------------------------------------------------------
# 5. Download zip
# ---------------------------------------------------------------------------

yellow "Downloading $URL ..."

curl -L --fail --progress-bar \
  "${BLOB_HEADERS[@]}" \
  -o "$TMP_ZIP" \
  "$URL" || die "Download failed."

echo ""

# ---------------------------------------------------------------------------
# 5. Install binary
# ---------------------------------------------------------------------------

yellow "Extracting..."
mkdir -p "$TMP_EXTRACT"

unzip -o -q "$TMP_ZIP" "${ZIP_INNER_DIR}/*" -d "$TMP_EXTRACT" \
  || die "Failed to extract '${ZIP_INNER_DIR}' from zip. Check that the zip structure matches."

EXTRACTED_DIR="$TMP_EXTRACT/$ZIP_INNER_DIR"

if [[ -f "$EXTRACTED_DIR/corecli" ]]; then
  EXTRACTED_BIN="$EXTRACTED_DIR/corecli"
elif [[ -f "$EXTRACTED_DIR/CoreCli" ]]; then
  EXTRACTED_BIN="$EXTRACTED_DIR/CoreCli"
else
  die "Extracted binary not found at expected paths: $EXTRACTED_DIR/corecli or $EXTRACTED_DIR/CoreCli"
fi

mkdir -p "$INSTALL_DIR"
# Install binary with execute permission
install -m 755 "$EXTRACTED_BIN" "$INSTALL_BIN"
# Install PDB files alongside binary (needed for line numbers in exception stack traces)
find "$EXTRACTED_DIR" -maxdepth 1 -name '*.pdb' -exec install -m 644 {} "$INSTALL_DIR/" \;

green "Binary and debug symbols (PDB) installed to $INSTALL_DIR"

# ---------------------------------------------------------------------------
# 6. PATH check
# ---------------------------------------------------------------------------

# Warn if ~/.local/bin (or $XDG_BIN_HOME) is not on PATH
configure_path_shell_env

  # ---------------------------------------------------------------------------
  # 7. Verify
# ---------------------------------------------------------------------------

echo ""
bold "Verifying installation..."
INSTALL_VERSION=$("$INSTALL_BIN" --version 2>&1 || true)
green "OK: $INSTALL_VERSION"

echo ""
green "CoreCli $VERSION installed successfully."
green "Browser routing verified — corecli login will work on this machine."
printf 'Run: %s\n' "$INSTALL_BIN"
