# Scripts Release Notes

## Installer 2026-09-16.1

### Bug Fixes

- Fixed macOS Bash 3.2 compatibility when no required packages are missing and `set -u` is enabled.

## Installer 2026-09-15.1

### Summary

Added platform-aware release selection for Linux and macOS, including an opt-in preview channel.

### Included Functionality

- Detects Linux or macOS and selects the matching x64 or ARM64 release package.
- Opens the Entra authentication URL with macOS `open` on native macOS.
- Supports `--rid` for a validated, host-compatible release-target override.
- Downloads RID-specific JSON manifests containing release metadata and release notes.
- Supports `--preview` to install from `preview-<RID>.json` without changing the stable channel.
- Displays release notes before downloading the selected release.
- Applies ICU and `apt-get` setup only on Linux; macOS retains prerequisite validation without Linux package installation.

### Guardrails

- Rejects unsupported operating systems, CPU architectures, and incompatible `--rid` values before authentication.
- Keeps the stable `latest-<RID>.json` channel separate from preview manifests.

## Installer 2026-04-30.1

### Summary

The current installer script provides a full WSL/Linux bootstrap flow for CoreCli.

### Included Functionality

- Supports Entra PKCE browser authentication for downloading releases from the private Azure Blob container.
- Bootstraps missing `curl`, `unzip`, `python3`, and ICU packages with `apt-get`.
- Configures Microsoft Edge as `BROWSER` on WSL and persists it to the detected shell rc file.
- Installs CoreCli into `~/.local/bin` by default.
- Downloads and installs `proxy-toggle.sh` into the install directory.
- Adds a `proxy()` shell function to the detected shell rc file.
- Persists the install directory to `PATH` when required.
- Supports non-interactive mode via `--yes`.
- Prints installer diagnostics in debug mode, including the installer script version.
- Verifies the installed CoreCli binary by running `--version`.

### Guardrails

- Shell rc updates for `PATH`, `BROWSER`, and `proxy()` are append-only and idempotent.
- Existing user-owned `BROWSER` settings are not overwritten.
- The installer prints the exact `source ...` command needed when it cannot reload the parent shell automatically.
- WSL browser launching includes checks to avoid fragile `xdg-open` wrapper behavior.

### Notes

- When the installer is executed with `bash <(...)`, the parent shell must still run the printed `source ...` command.
- When connected to the Telia Umeå office network or the Telia VPN, users should enable the installed proxy helper with `proxy on`.
