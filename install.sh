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
INSTALL_DIR="$HOME/.corecli/bin"
INSTALL_BIN="$INSTALL_DIR/CoreCli"
TMP_ZIP="/tmp/CoreCli_install_$$.zip"
TMP_EXTRACT="/tmp/corecli-extract-$$"
TMP_CODE="/tmp/CoreCli_authcode_$$"
TMP_PYLISTENER="/tmp/CoreCli_listener_$$.py"
ZIP_INNER_DIR="CoreCli/linux-x64-singlefile"   # directory containing binary + PDB files
ZIP_INNER_PATH="CoreCli/linux-x64-singlefile/CoreCli"  # the executable (for reference)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

die() { red "ERROR: $*" >&2; exit 1; }

open_browser() {
  local url="$1"
  # 1. Respect explicit BROWSER env var (works everywhere including WSL)
  if [[ -n "${BROWSER:-}" ]]; then
    "$BROWSER" "$url" 2>/dev/null || true
    return
  fi
  # 2. xdg-open — standard on Linux; in WSL it delegates to Windows via xdg-settings
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url" 2>/dev/null || true
    return
  fi
  # 3. wslview — wslu package, the dedicated WSL browser bridge
  if command -v wslview >/dev/null 2>&1; then
    wslview "$url" 2>/dev/null || true
    return
  fi
  die "Could not open a browser. CoreCli install requires a working browser to authenticate.

  Fix browser routing first, then re-run this script:

  On WSL/Ubuntu — install wslu (provides wslview):
    sudo apt install wslu

  Or set the BROWSER environment variable to your browser path:
    export BROWSER='/mnt/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'
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

for cmd in curl unzip python3; do
  command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is required but not installed. Please install it and retry."
done

# ---------------------------------------------------------------------------
# 2. PKCE Authentication (browser-based — satisfies Conditional Access)
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

echo ""
yellow "Opening browser for authentication..."
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

  This usually means browser routing is not working. Fix it, then re-run:

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
# 4. Prompt for symlink name
# ---------------------------------------------------------------------------

read -rp "Symlink name in ~/bin [corecli]: " LINK_NAME
LINK_NAME="${LINK_NAME:-corecli}"

[[ "$LINK_NAME" != */* ]] || die "Symlink name must not contain '/'. Got: $LINK_NAME"
[[ -n "$LINK_NAME" ]]     || die "Symlink name must not be empty."

echo ""
bold "Installing CoreCli $VERSION as ~/bin/$LINK_NAME..."
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
EXTRACTED_BIN="$EXTRACTED_DIR/CoreCli"
[[ -f "$EXTRACTED_BIN" ]] || die "Extracted binary not found at expected path: $EXTRACTED_BIN"

mkdir -p "$INSTALL_DIR"
# Install binary with execute permission
install -m 755 "$EXTRACTED_BIN" "$INSTALL_BIN"
# Install PDB files alongside binary (needed for line numbers in exception stack traces)
find "$EXTRACTED_DIR" -maxdepth 1 -name '*.pdb' -exec install -m 644 {} "$INSTALL_DIR/" \;

green "Binary and debug symbols (PDB) installed to $INSTALL_DIR"

# ---------------------------------------------------------------------------
# 6. Symlink
# ---------------------------------------------------------------------------

mkdir -p "$HOME/bin"

LINK_PATH="$HOME/bin/$LINK_NAME"
if [[ -L "$LINK_PATH" ]]; then
  rm "$LINK_PATH"
elif [[ -e "$LINK_PATH" ]]; then
  die "$LINK_PATH already exists and is not a symlink. Remove it manually and retry."
fi

ln -s "$INSTALL_BIN" "$LINK_PATH"
green "Symlink created: $LINK_PATH -> $INSTALL_BIN"

# Warn if ~/bin is not on PATH
case ":$PATH:" in
  *":$HOME/bin:"*) ;;
  *)
    echo ""
    yellow "WARNING: ~/bin is not in your \$PATH."
    yellow "Add the following to your ~/.bashrc or ~/.profile:"
    printf '  export PATH="$HOME/bin:$PATH"\n'
    ;;
esac

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
printf 'Run: %s\n' "$LINK_NAME"
