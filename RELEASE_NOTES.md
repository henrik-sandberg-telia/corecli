# Scripts Release Notes

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
