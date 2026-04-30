# Scripts

This folder contains the shell scripts used to install and support CoreCli in WSL/Linux environments.

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

## What `install.sh` Does

The installer is designed for WSL/Linux and performs these steps in order:

1. Validates runtime prerequisites and can install missing `curl`, `unzip`, `python3`, and ICU packages with `apt-get`.
2. Detects WSL and configures `BROWSER` to use Microsoft Edge for the installer session.
3. Persists `BROWSER` to the detected shell rc file unless the user opts out with `--no-setup-browser`.
4. Starts an Entra PKCE browser authentication flow against the CoreCli app registration.
5. Reads `latest.txt` from the Azure Blob releases container.
6. Downloads the latest CoreCli release zip.
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
- `--yes`, `-y`, or `--non-interactive`: auto-accepts installer prompts and uses default values.
- `--setup-browser`: forces browser persistence logic on WSL.
- `--no-setup-browser`: skips browser persistence logic on WSL.
- `--help` or `-h`: shows usage.

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
