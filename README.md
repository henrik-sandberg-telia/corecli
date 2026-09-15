# Scripts

This folder contains shell scripts used to install and support CoreCli on Linux, WSL, and macOS.

## Install Script

The main entry point is `install.sh`.

Run it locally from the repository root:

```bash
./scripts/install.sh
```

Run it with debug output:

```bash
./scripts/install.sh --debug
```

Published one-liner install command used by the project documentation:

```bash
command -v curl >/dev/null 2>&1 || { sudo apt-get update && sudo apt-get install -y curl; }
bash <(curl -fsSL https://raw.githubusercontent.com/henrik-sandberg-telia/corecli/main/install.sh)
```

Unattended variant:

```bash
command -v curl >/dev/null 2>&1 || { sudo apt-get update && sudo apt-get install -y curl; }
bash <(curl -fsSL https://raw.githubusercontent.com/henrik-sandberg-telia/corecli/main/install.sh) --yes
```

## State Service Mock (`state_service_mock.py`)

`state_service_mock.py` is a self-contained local mock of the SPT State Service for
manually testing the `corecli state ...` commands against fleets of fake
devices/RWOs in **dev** mode. It uses only the Python standard library
(`http.server`, `ssl`, `json`).

In dev, `CoreAPI.State` points at `https://localhost:5001` with SSL validation
bypassed, so the mock serves HTTPS there using a self-signed certificate that is
generated once (via `openssl`) into `scripts/.state-mock/`.

Run it:

```bash
python3 scripts/state_service_mock.py            # HTTPS on localhost:5001
python3 scripts/state_service_mock.py --http     # plain HTTP (debugging)
python3 scripts/state_service_mock.py --port 8443 --host 0.0.0.0
```

Then, in another shell:

```bash
corecli env dev
corecli login                                    # once; the mock ignores the token
corecli state get -d 0009d805884c,0009d805884d   # fan-out over a fake fleet
corecli state reported -d 0009d805884c --property config
corecli state set-desired -d 0009d805884c --property firmware_version --value 1.5.0
corecli state desired -d 0009d805884c            # shows the override
```

> The CLI validates `-d/--devices` as MAC addresses (12 hex digits, with or without
> `:` separators), so use MAC-shaped ids like above. The mock itself accepts *any*
> id — handy for direct `curl` testing, or pass
> `--skip-device-serial-validation` to bypass the CLI check.

Behavior:

- **Any id works** — reported/desired state is auto-generated deterministically
  per id (stable across GETs). Reported includes `firmware_version`,
  `battery_level`, `connection_status`, and a nested `config` object (to exercise
  the multi-line table cell rendering).
- **`set-desired` persists in-memory** for the process lifetime; the override
  wins over generated state on subsequent reads.
- **Auth is ignored** — the mock does not validate the `Authorization` header, but
  the CLI still acquires a real Entra token in dev, so you run `corecli login`
  once as usual.
- **History** returns `{ "data": [ { "timestamp", "value" }, ... ] }` — a
  deterministic synthetic numeric time series per reported property (12 points at
  5-minute intervals). History is only served for the `reported` section; requesting
  it on `desired` returns `404`.
- **Error simulation** for testing fan-out/error rendering:
  - id `notfound` (or prefix `notfound`) or MAC `00:00:00:00:00:00` → `404`
  - id `boom` or MAC `00:00:00:00:00:01` → `500`
  - `set-desired` with property `unsupported` → `400` (`unsupported-state-key`)
  - `set-desired` against an RWO → `405` (desired is read-only for RWOs)

The generated certificate directory (`scripts/.state-mock/`) is disposable; delete
it to force a new certificate on the next run.

## What `install.sh` Does

The installer supports Linux x64/ARM64 and macOS x64/ARM64. It performs these steps in order:

1. Detects a compatible release RID from the host OS and CPU architecture.
2. Validates runtime prerequisites and, on Linux only, can install missing `curl`, `unzip`, `python3`, and ICU packages with `apt-get`.
2. Detects WSL and configures `BROWSER` to use Microsoft Edge for the installer session.
3. Persists `BROWSER` to the detected shell rc file unless the user opts out with `--no-setup-browser`.
4. Starts an Entra PKCE browser authentication flow against the CoreCli app registration.
5. Reads `latest-<RID>.json` from the Azure Blob releases container and displays its release notes.
6. Downloads the matching CoreCli release zip.
7. Extracts and installs the CoreCli binary into `~/.local/bin` by default, or `$XDG_BIN_HOME` if set.
8. Installs PDB files alongside the binary for better exception stack traces.
9. Downloads `proxy-toggle.sh` into the install directory.
10. Persists `PATH` updates to the detected shell rc file when the install directory is not already present.
11. Adds a `proxy()` shell function to the detected shell rc file.
12. Verifies the installed binary by running `--version`.

## Installed Files And Shell Changes

By default, the installer writes these files:

- `~/.local/bin/corecli`
- `~/.local/bin/*.pdb`
- `~/.local/bin/proxy-toggle.sh`

It may also append configuration to the user shell rc file, depending on shell detection:

- `~/.bashrc`
- `~/.zshrc`
- `~/.profile`

The rc updates can include:

- `export BROWSER="/mnt/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"`
- `export PATH="<install-dir>:$PATH"`
- a `proxy()` function that sources `proxy-toggle.sh`

The proxy helper added to the rc file has this shape:

```bash
proxy() {
    source "~/.local/bin/proxy-toggle.sh" "$@"
}
```

At runtime the installer writes the real install path, not the literal `~/.local/bin` example above.

## Command-Line Options

`install.sh` supports these flags:

- `--debug` or `-d`: prints installer version, shell context, auth URL diagnostics, and browser launcher diagnostics.
- `--rid <RID>`: overrides platform detection only when the RID is compatible with the current host. Supported values are `linux-x64`, `linux-arm64`, `osx-x64`, and `osx-arm64`.
- `--yes`, `-y`, or `--non-interactive`: auto-accepts installer prompts and uses default values.
- `--setup-browser`: forces browser persistence logic on WSL.
- `--no-setup-browser`: skips browser persistence logic on WSL.
- `--help` or `-h`: shows usage.

## Preview Updates

`corecli check-updates --preview` and `./scripts/install.sh --preview` read `preview-<RID>.json` instead of the stable `latest-<RID>.json` manifest. Preview manifests are created only by tags with a suffix, such as `v2.3.1-preview.1`; they do not change the stable update channel.

## Shell Detection And Reload Behavior

The installer auto-detects the rc file based on the active shell:

- bash: `~/.bashrc`
- zsh: `~/.zshrc`
- fallback: first existing file among `~/.zshrc`, `~/.bashrc`, `~/.profile`, otherwise `~/.profile`

When the script is executed normally, for example with `bash <(...)`, it cannot modify the parent shell environment. In that case it prints a visible reminder telling the user exactly which `source ...` command to run.

When the script itself is sourced, it can reload the detected rc file into the current shell session.

## Proxy Helper

The companion `proxy-toggle.sh` script toggles a predefined Telia office proxy configuration on and off by setting or unsetting:

- `http_proxy`
- `https_proxy`
- `HTTP_PROXY`
- `HTTPS_PROXY`
- `ftp_proxy`
- `FTP_PROXY`
- `no_proxy`
- `NO_PROXY`

After installation and rc reload, the helper can be used as:

```bash
proxy status
proxy on
proxy off
```

Use `proxy on` when connected to the Telia Umea office network or the Telia VPN.

## Guardrails

The installer includes these guardrails:

- It never embeds secrets; Azure Blob access is delegated through Entra ID and RBAC.
- It validates required auth URL parameters before opening the browser.
- It prefers a real Windows browser executable in WSL and warns about fragile `xdg-open` wrapper setups.
- It installs missing packages only through explicit user confirmation, unless `--yes` is passed.
- It keeps shell updates idempotent by checking for existing `BROWSER`, `PATH`, and `proxy()` configuration before appending.
- It does not overwrite an existing user-owned `BROWSER` export with a different value.
- It prints the exact rc file reload command the user must run when the installer cannot update the parent shell directly.
- It verifies the final CoreCli installation by executing the installed binary with `--version`.

## Summary

`install.sh` is more than a file downloader. It bootstraps dependencies, fixes browser routing for WSL, installs CoreCli, installs the proxy helper, updates the correct shell rc file, and leaves the user with a verified binary plus a clear reload command for the current shell.
