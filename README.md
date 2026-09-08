# bootstrapper

Turn a fresh **Kali** or **Ubuntu** VPS into a ready-to-use recon / pentest
workstation with one command. `bootstrapper` detects the distribution, configures
users and shells, installs the Go and Rust toolchains, the full
[ProjectDiscovery](https://github.com/projectdiscovery) suite, a curated recon
toolkit, and the v2ray / v2rayA proxy stack — idempotently, with a live progress
display and a timed summary.

It is built to survive hostile networks: unreliable DNS, sanctioned endpoints,
and CDN caching are all handled so the run completes instead of dying halfway.

---

## Requirements

- Kali Rolling or Ubuntu (Debian-family), `amd64` or `arm64`.
- Root — the script re-executes itself with `sudo` when needed.
- Outbound access to GitHub, the Go proxy, PyPI, and the distribution mirrors.

## Installation

Via the jsDelivr CDN (recommended — reachable where `raw.githubusercontent.com`
is not):

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/mojtaba13133/bootstrapper@main/install.sh | bash
```

Directly from GitHub:

```bash
curl -fsSL https://raw.githubusercontent.com/mojtaba13133/bootstrapper/main/install.sh | bash
```

Forward options through the pipe with `-s --`:

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/mojtaba13133/bootstrapper@main/install.sh | bash -s -- --user hunter --force
```

Or clone and run locally:

```bash
git clone https://github.com/mojtaba13133/bootstrapper.git
cd bootstrapper && sudo bash provision.sh
```

`install.sh` downloads `provision.sh` (jsDelivr first, then GitHub raw, each with
retries), elevates with `sudo`, and reconnects the terminal so prompts work even
over a pipe. The startup banner prints the version — check it matches what you
expect. jsDelivr caches `@main` for a while; pin a tag or commit
(`@v2.7.0`) for a guaranteed-fresh, reproducible install.

## Usage

```
sudo ./provision.sh [options]

  --user <name>       Normal user to configure (default: auto-detected)
  --set-passwords     Prompt to set root/user passwords
  --no-passwords      Never touch passwords
  --non-interactive   No prompts; use defaults
  --force             Reinstall tools even if already present
  --list-tools        Print the tool catalogue and exit
  -V, --version       Print version and exit
  -h, --help          Show help
```

## Configuration

Every stage is toggled by an environment variable (default `1`):

```bash
INSTALL_V2RAY=0 INSTALL_SECLISTS=0 sudo ./provision.sh
```

| Variable | Effect |
|----------|--------|
| `INSTALL_ZSH` `INSTALL_GO` `INSTALL_RUST` `INSTALL_PDTM` | Toggle the shell / toolchain stages |
| `INSTALL_EXTRA_TOOLS` `INSTALL_SECLISTS` | Toggle the recon toolkit / the ~1 GB SecLists download |
| `INSTALL_V2RAY` `INSTALL_V2RAYA` | Toggle the proxy stack |
| `PDTM_FOR_ROOT` | Also install the ProjectDiscovery suite for `root` |
| `FORCE_REINSTALL` | Reinstall even when a tool is already present |
| `NORMAL_USER` `GO_VERSION` `TOOLS_DIR` `GOPROXY` | Override the user, Go version, clone dir, Go proxy |

## How it works

The run is a fixed pipeline; each stage is timed and its result (`OK` / `SKIP` /
`FAIL`) appears in the final summary:

1. **DNS** — writes a reliable resolver set to `/etc/resolv.conf` (Shecan first,
   then Cloudflare and Google) and backs up the original.
2. **Passwords** — optionally sets `root` / user passwords.
3. **Base system** — `apt` update and core build/runtime packages.
4. **Kali repo (Ubuntu only)** — adds `kali-rolling` with strict apt pinning.
5. **zsh** — installs and sets it as the default shell for `root` and the user.
6. **v2ray core** and **7. v2rayA GUI** — the proxy stack (web UI on port `2017`).
8. **Network gate** — verifies `go.dev` is reachable before the Go-dependent
   stages (see *Networking*).
9. **Go** and **10. Rust** — toolchains, wired system-wide.
11. **ProjectDiscovery** — `pdtm` plus the full tool suite and nuclei templates.
12. **Recon toolkit** — `ffuf`, `gau`, `hakrawler`, `VhostFinder`, `amass`,
    `arjun`, `dirsearch`, `nmap`, `massdns`, `sqlmap`, `BackupKiller`, `x8`,
    `SecLists`.

Run `sudo ./provision.sh --list-tools` for the full catalogue. Git-cloned tools
live in `/opt/tools` with launchers on `PATH` in `/usr/local/bin`.

## Networking

The script targets environments where common endpoints are blocked or flaky:

- **DNS** — Shecan (`178.22.122.100` / `185.51.200.2`) resolves sanctioned dev
  services such as `go.dev` to unblocking proxy IPs; Cloudflare and Google follow
  as general fallback.
- **Go** — `GOPROXY=https://proxy.golang.org,direct` (unblocked by Shecan) with a
  `direct` fallback; `GOSUMDB=off`.
- **Rust** — tries `rustup`, then falls back to the distribution's `rustc` /
  `cargo` if `sh.rustup.rs` is unreachable.
- **v2ray / v2rayA** — the core installer is fetched via jsDelivr, and v2rayA is
  installed from a GitHub release `.deb`, avoiding the blocked `apt.v2raya.org`.
- **Unstable links** — every network step retries with timeouts (including on
  DNS/connection errors), and country detection falls back across several services
  (`ifconfig.io`, `api.ipmyp.ir`, `ipinfo.io`, `api.country.is`). If a stage still
  fails, the run pauses and offers to retry it rather than silently skipping — so a
  dropped download doesn't leave a half-provisioned box.
- **Network gate** — if Go is not already installed and `go.dev` is unreachable,
  the run pauses with instructions to bring up the proxy (TProxy mode) and
  re-checks until `go.dev` responds. If Go is already installed, it proceeds.

## Logs & idempotency

Full command output is written to `/var/log/provision-<timestamp>.log` (falling
back to `/tmp`); the terminal shows only progress and results. Re-running is
cheap — installed components report `SKIP`, and large downloads are not re-fetched.
After the run, load the new shell and `PATH` with `exec zsh` or a fresh login.

## Security

- On Ubuntu the Kali repository is added with apt pinning (priority `50`), so Kali
  packages are only ever installed on demand (`apt install -t kali-rolling <pkg>`)
  and never override the Ubuntu base system.
- This installs offensive-security tooling. Use it only against systems you own or
  are explicitly authorised to test.

## License

MIT — see [`LICENSE`](LICENSE).
