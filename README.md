# provision.sh

A single-command bootstrapper that turns a fresh **Kali** or **Ubuntu** VPS into
a ready-to-use recon / pentest workstation. It detects the distribution,
configures users and shells, installs the Go and Rust toolchains, the full
[ProjectDiscovery](https://github.com/projectdiscovery) suite, a curated recon
toolkit, and the v2ray / v2rayA proxy stack — **idempotently**, with a live
progress display and a timed summary.

> Built for people who spin up throwaway boxes often and don't want to
> hand-install and reconfigure the same stack every time.

---

## Features

- **Distro-aware** — detects Kali vs. Ubuntu and CPU architecture (amd64 / arm64).
- **Idempotent** — safe to re-run; anything already installed is skipped. Use
  `--force` to reinstall.
- **Self-contained** — no prerequisites; the script fetches whatever it needs.
- **Resilient on filtered networks** — mirrors and fallbacks so the common
  blockers (Google's Go proxy, `sh.rustup.rs`, the v2rayA site) don't stop the run.
- **Fault-isolated** — every stage and every tool is independent; one failure
  never aborts the rest.
- **Readable output** — noisy command output goes to a timestamped log file; the
  terminal shows a progress bar, per-tool results, and a final report with timings.

## What it installs

| Stage | Contents |
|-------|----------|
| Base system | `curl wget git build-essential pkg-config libpcap-dev libssl-dev python3 pipx jq` … |
| Shell | `zsh` set as the default shell for `root` and the normal user |
| Go | Latest stable Go, wired system-wide (`/etc/profile.d`, `/etc/zsh/zshenv`) |
| Rust | `rustup` (with an apt `rustc`/`cargo` fallback) |
| ProjectDiscovery | `pdtm` + all PD tools (`subfinder`, `httpx`, `nuclei`, `naabu`, `katana`, `dnsx`, …) + nuclei templates |
| Recon toolkit | `ffuf`, `gau`, `hakrawler`, `VhostFinder`, `amass`, `arjun`, `dirsearch`, `nmap`, `massdns`, `sqlmap`, `BackupKiller`, `x8`, `SecLists` |
| Proxy | `v2ray` core + `v2rayA` GUI (web UI on port `2017`) |

Run `sudo ./provision.sh --list-tools` for the full catalogue.

## Requirements

- Kali Rolling or Ubuntu (Debian-like), amd64 or arm64.
- `root` (the script re-executes itself with `sudo` if needed).
- Outbound access to GitHub, `go.dev`, the Go module mirror, PyPI, and the apt
  repositories.

## Installation

Recommended — via the jsDelivr CDN (fast and reliable, including on filtered networks):

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/mojtaba13133/bootstrapper@main/install.sh | bash
```

Directly from GitHub:

```bash
curl -fsSL https://raw.githubusercontent.com/mojtaba13133/bootstrapper/main/install.sh | bash
```

Pass options through with `-s --`:

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/mojtaba13133/bootstrapper@main/install.sh | bash -s -- --user hunter --force
```

Or clone and run locally:

```bash
git clone https://github.com/mojtaba13133/bootstrapper.git
cd <repo> && chmod +x provision.sh
sudo ./provision.sh
```

The installer downloads `provision.sh` (with mirror fallback and retries),
elevates with `sudo`, and reconnects the terminal so the interactive prompts work
even when piped. Set `NONINTERACTIVE=1` for unattended runs.

> **jsDelivr caching.** `@main` URLs are cached by the CDN for a while, so right
> after pushing you may get an older copy. For a guaranteed-fresh install, pin a
> tag or commit — e.g. `@v2.4.1` instead of `@main` — or purge the cache once:
>
> ```bash
> curl -s https://purge.jsdelivr.net/gh/mojtaba13133/bootstrapper@main/install.sh
> curl -s https://purge.jsdelivr.net/gh/mojtaba13133/bootstrapper@main/provision.sh
> ```
>
> The banner printed at startup shows the version — confirm it matches what you pushed.

## Usage

```
sudo ./provision.sh [options]

  --user <name>        Normal user to configure (default: auto-detected)
  --set-passwords      Prompt to set root/user passwords
  --no-passwords       Never touch passwords
  --non-interactive    No prompts; use defaults
  --force              Reinstall tools even if already present
  --list-tools         Print the tool catalogue and exit
  -V, --version        Print version and exit
  -h, --help           Show help
```

## Configuration

Any stage can be toggled with an environment variable (default `1`):

```bash
INSTALL_V2RAY=0 INSTALL_SECLISTS=0 sudo ./provision.sh
```

| Variable | Purpose |
|----------|---------|
| `INSTALL_ZSH` `INSTALL_GO` `INSTALL_RUST` `INSTALL_PDTM` | Toggle toolchain / shell stages |
| `INSTALL_EXTRA_TOOLS` `INSTALL_SECLISTS` | Toggle the recon toolkit / the large SecLists download |
| `INSTALL_V2RAY` `INSTALL_V2RAYA` | Toggle the proxy stack |
| `PDTM_FOR_ROOT` | Also install the PD suite for `root` (default `1`) |
| `FORCE_REINSTALL` | Reinstall even when a tool is already present |
| `NORMAL_USER` `GO_VERSION` `TOOLS_DIR` | Override the user, pinned Go version, git-clone directory |

## Adding a tool

Tools are intentionally **explicit** rather than generated from a generic
abstraction: each one gets its own function so tool-specific quirks and failures
can be handled directly. Adding a tool is two steps.

1. Write a `tool_<name>` function that returns `0` on success, `3` to skip
   (already installed), or non-zero on failure:

   ```bash
   tool_waybackurls() {
     present waybackurls && return 3
     go_install_global "github.com/tomnomnom/waybackurls@latest"
   }
   ```

   Reusable helpers are available: `present`, `go_install_global`, `apt_tool`,
   `clone_tool`, and `make_launcher`.

2. Register it in the `TOOLKIT` array (`name|description|function`):

   ```bash
   "waybackurls|Wayback URL fetcher|tool_waybackurls"
   ```

Adding a whole new **stage** is likewise one line in the `PIPELINE` array.

## Logging & idempotency

- Full output is written to `/var/log/provision-<timestamp>.log` (falls back to
  `/tmp` if `/var/log` isn't writable). If a stage shows `FAIL`, the details are
  there.
- Re-running is cheap: installed tools report `SKIP`, and large downloads such as
  SecLists are not re-fetched.

## Filtering resilience

The script is designed to work from networks where common endpoints are blocked:

- **Go** — `GOPROXY=https://goproxy.cn,direct` and `GOSUMDB=off`, because
  `proxy.golang.org` and `sum.golang.org` are geo-blocked in some regions and
  otherwise cause `403` failures during `go install`.
- **Rust** — tries `rustup`, then falls back to the distro's `rustc` / `cargo`
  packages if `sh.rustup.rs` is unreachable.
- **v2rayA** — installs the `.deb` straight from GitHub Releases instead of the
  frequently blocked `apt.v2raya.org`.
- **v2ray core** — the installer script is fetched from the jsDelivr mirror first,
  then `raw.githubusercontent.com`.
- **Bootstrapper** — `install.sh` fetches `provision.sh` from jsDelivr, then raw,
  each with retries, so a flaky `raw.githubusercontent.com` doesn't stop the install.
- **Iran network gate** — v2ray/v2rayA are installed *before* the Go/Rust/PD
  stages. If Go isn't already present and the exit IP is in Iran (checked via
  `ifconfig.io/country_code`), the installer pauses with step-by-step instructions
  to bring up the proxy in TProxy mode, then re-checks and only continues once the
  exit IP is outside Iran (where `go.dev` is filtered). If Go is already installed,
  it proceeds regardless of location.

## Post-install

- Load the new shell and `PATH`: `exec zsh` (or log out and back in).
- v2rayA: open `http://<server-ip>:2017`, import your config, enable **TProxy**,
  press **Start**, then verify with `curl ifconfig.io`.
- Git-cloned tools live under `/opt/tools`, with launchers on `PATH` in
  `/usr/local/bin`.

## Security notes

- On Ubuntu the Kali repository is added with **apt pinning** (priority `50`), so
  Kali packages are only ever installed on demand
  (`apt install -t kali-rolling <pkg>`) and never override the Ubuntu base system.
- This installs offensive-security tooling. Use it **only** against systems you
  own or are explicitly authorised to test.

## License

MIT. See [`LICENSE`](LICENSE).
