#!/usr/bin/env bash
# =============================================================================
#  provision.sh — Recon / Pentest VPS bootstrapper for Kali & Ubuntu
# -----------------------------------------------------------------------------
#  Bootstraps a fresh VPS in a single command: detects the distribution,
#  configures users and shells, installs the Go/Rust toolchains, the full
#  ProjectDiscovery suite, a curated recon toolkit, and the v2ray/v2rayA proxy
#  stack — idempotently, with a live progress display and a timed summary.
#
#  Noisy command output is streamed to a timestamped log file; the terminal
#  shows only progress, per-item results, and the final report.
#
#  Each recon tool has its own dedicated install function (see SECTION 9), so
#  tool-specific quirks and failures are handled explicitly rather than through a
#  generic abstraction.
#
#  Usage:
#    sudo ./provision.sh                     # interactive
#    sudo ./provision.sh --user hunter       # choose the normal user
#    sudo ./provision.sh --list-tools        # print the tool catalogue and exit
#    sudo ./provision.sh --force             # reinstall tools even if present
#    sudo NONINTERACTIVE=1 ./provision.sh    # no prompts
#    curl -fsSL <url>/install.sh | bash      # one-line remote install
#
#  Component toggles (env vars, default 1):
#    INSTALL_ZSH INSTALL_GO INSTALL_RUST INSTALL_PDTM INSTALL_EXTRA_TOOLS
#    INSTALL_SECLISTS INSTALL_V2RAY INSTALL_V2RAYA PDTM_FOR_ROOT
#
#  License: MIT.  Use only against systems you are authorised to test.
# =============================================================================

set -uo pipefail   # deliberately no -e: each stage handles its own errors so a
                   # single failure never aborts the whole run.

readonly SCRIPT_VERSION="2.6.0"
readonly SCRIPT_NAME="${0##*/}"

# =============================================================================
#  SECTION 1 — Terminal styling & logging
# =============================================================================
if [[ -t 1 ]]; then
  readonly TTY=1
  readonly C_RESET=$'\e[0m'  C_BOLD=$'\e[1m'   C_DIM=$'\e[2m'
  readonly C_RED=$'\e[31m'   C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m'
  readonly C_BLUE=$'\e[34m'  C_CYAN=$'\e[36m'
else
  readonly TTY=0
  readonly C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
fi

log()       { printf '%s[*]%s %s\n'  "$C_BLUE"   "$C_RESET" "$*"; }
log_ok()    { printf '%s[+]%s %s\n'  "$C_GREEN"  "$C_RESET" "$*"; }
log_warn()  { printf '%s[!]%s %s\n'  "$C_YELLOW" "$C_RESET" "$*"; }
log_error() { printf '%s[-]%s %s\n'  "$C_RED"    "$C_RESET" "$*" >&2; }

# Human-readable duration, e.g. 93 -> "1m33s".
fmt_dur() {
  local s=$1
  (( s >= 60 )) && printf '%dm%02ds' $(( s / 60 )) $(( s % 60 )) || printf '%ds' "$s"
}

# =============================================================================
#  SECTION 2 — Long-running command runner (spinner + logging)
# =============================================================================
LOG_FILE=""   # assigned in main() once we are root

# _run "<label>" <cmd...> : run a command, stream its output to the log file,
# and show a spinner (on a TTY) so long installs never look frozen.
_run() {
  local label="$1"; shift
  local rc
  if (( TTY )); then
    ( "$@" ) >>"$LOG_FILE" 2>&1 &
    local pid=$! frames=('|' '/' '-' $'\\') i=0
    tput civis 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
      printf '\r  %s%s%s %s\e[K' "$C_CYAN" "${frames[i++ % 4]}" "$C_RESET" "$label"
      sleep 0.1
    done
    wait "$pid"; rc=$?
    printf '\r\e[K'
    tput cnorm 2>/dev/null || true
  else
    printf '  ... %s\n' "$label"
    "$@" >>"$LOG_FILE" 2>&1; rc=$?
  fi
  return "$rc"
}

# =============================================================================
#  SECTION 3 — Small utilities
# =============================================================================
have()    { command -v "$1" >/dev/null 2>&1; }
is_root() { [[ "$(id -u)" -eq 0 ]]; }

# Run a command in a login shell as a given user (loads PATH / go env).
run_as() {
  local user="$1"; shift
  if [[ "$user" == "root" ]]; then
    bash -lc "$*"
  else
    sudo -u "$user" -H bash -lc "$*"
  fi
}

# True only if the controlling terminal can actually be opened. `-r /dev/tty`
# is not enough: the device node can exist yet be unopenable (no ctty), so we
# probe it for real.
have_tty() { (exec </dev/tty) 2>/dev/null; }

# Read one line from the controlling terminal, even when stdin is a pipe (as
# with `curl ... | bash`). Leaves the variable empty if no terminal is available.
read_tty() {
  local __var="$1" __prompt="$2" __line=""
  have_tty && { read -r -p "$__prompt" __line </dev/tty || __line=""; }
  printf -v "$__var" '%s' "$__line"
}

# Yes/no prompt; honours NONINTERACTIVE and works with no terminal.
ask_yn() {
  local prompt="$1" default="${2:-y}" reply
  if [[ "${NONINTERACTIVE:-0}" == "1" ]] || ! have_tty; then
    [[ "$default" == "y" ]]; return
  fi
  read_tty reply "$prompt [$( [[ $default == y ]] && echo Y/n || echo y/N )] "
  [[ "${reply:-$default}" =~ ^[Yy]$ ]]
}

# =============================================================================
#  SECTION 4 — Configuration (env overrides + CLI flags)
# =============================================================================
NORMAL_USER="${NORMAL_USER:-}"
SET_PASSWORDS="${SET_PASSWORDS:-}"
INSTALL_ZSH="${INSTALL_ZSH:-1}"
INSTALL_GO="${INSTALL_GO:-1}"
INSTALL_RUST="${INSTALL_RUST:-1}"
INSTALL_PDTM="${INSTALL_PDTM:-1}"
INSTALL_EXTRA_TOOLS="${INSTALL_EXTRA_TOOLS:-1}"
INSTALL_SECLISTS="${INSTALL_SECLISTS:-1}"
INSTALL_V2RAY="${INSTALL_V2RAY:-1}"
INSTALL_V2RAYA="${INSTALL_V2RAYA:-1}"
PDTM_FOR_ROOT="${PDTM_FOR_ROOT:-1}"
FORCE_REINSTALL="${FORCE_REINSTALL:-0}"
SKIP_NET=0   # set by the network gate when we can't route outside IR without Go

TOOLS_DIR="${TOOLS_DIR:-/opt/tools}"
GO_VERSION="${GO_VERSION:-}"

DO_LIST_TOOLS=0

usage() {
  if [[ -r "$0" && "$0" != "bash" && "$0" != "-bash" ]]; then
    grep -E '^#( |$)' "$0" | sed 's/^#\{1,\} \{0,1\}//'
  else
    printf '%s %s — recon/pentest VPS bootstrapper\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --user)            NORMAL_USER="$2"; shift 2 ;;
      --no-passwords)    SET_PASSWORDS=0;   shift ;;
      --set-passwords)   SET_PASSWORDS=1;   shift ;;
      --non-interactive) NONINTERACTIVE=1;  shift ;;
      --force)           FORCE_REINSTALL=1; shift ;;
      --list-tools)      DO_LIST_TOOLS=1;   shift ;;
      -V|--version)      printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; exit 0 ;;
      -h|--help)         usage; exit 0 ;;
      *) log_warn "Unknown argument: $1"; shift ;;
    esac
  done
}

# =============================================================================
#  SECTION 5 — OS / architecture detection
# =============================================================================
detect_os() {
  [[ -r /etc/os-release ]] || { log_error "/etc/os-release not found"; exit 1; }
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_NAME="${PRETTY_NAME:-$OS_ID}"
  case "$OS_ID" in
    kali)   IS_KALI=1; IS_UBUNTU=0 ;;
    ubuntu) IS_KALI=0; IS_UBUNTU=1 ;;
    *)      IS_KALI=0; IS_UBUNTU=0
            log_warn "Unrecognised distro '$OS_ID' — treating as Debian-like." ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)  GOARCH=amd64 ;;
    aarch64|arm64) GOARCH=arm64 ;;
    *) log_error "Unsupported architecture: $(uname -m)"; exit 1 ;;
  esac
  log_ok "Detected: ${C_BOLD}${OS_NAME}${C_RESET} (${OS_ID}/${GOARCH})"
}

# =============================================================================
#  SECTION 6 — Shared install primitives
# =============================================================================
export DEBIAN_FRONTEND=noninteractive

# Install an apt package; on Ubuntu, fall back to the pinned Kali repo.
apt_tool() {
  local pkg="$1"
  if (( IS_KALI )); then
    apt-get install -y "$pkg"
  elif (( IS_UBUNTU )) && [[ -f /etc/apt/sources.list.d/kali.list ]]; then
    apt-get install -y "$pkg" || apt-get install -y -t kali-rolling "$pkg"
  else
    apt-get install -y "$pkg"
  fi
}

# Install a Go tool system-wide (binary -> /usr/local/bin, usable by all users).
# GOPROXY uses the official proxy.golang.org (which Shecan DNS unblocks from IR,
# same family as go.dev) with a `direct` fallback that fetches straight from the
# module's VCS. GOSUMDB=off avoids a dependency on sum.golang.org. Override
# GOPROXY via env if you route through a proxy (e.g. a working v2ray tunnel).
go_install_global() {
  GOBIN=/usr/local/bin GOPATH=/root/go GOFLAGS=-buildvcs=false \
  GOPROXY="${GOPROXY:-https://proxy.golang.org,direct}" GOSUMDB="${GOSUMDB:-off}" \
    /usr/local/go/bin/go install -v "$1"
}

# Clone (shallow) or fast-forward a git repo under $TOOLS_DIR, owned by the user.
clone_tool() {
  local url="$1" dir="$2"
  if [[ -d "$dir/.git" ]]; then
    git -C "$dir" pull --ff-only || true
  else
    git clone --depth 1 "$url" "$dir" || return 1
  fi
  chown -R "$NORMAL_USER:$NORMAL_USER" "$dir" 2>/dev/null || true
}

# Write a tiny launcher into /usr/local/bin so a cloned tool is callable by name.
make_launcher() {
  local name="$1" cmd="$2"
  cat >"/usr/local/bin/$name" <<EOF
#!/usr/bin/env bash
exec $cmd "\$@"
EOF
  chmod 755 "/usr/local/bin/$name"
}

# Skip helper: true when a binary is already present and we are not forcing.
present() {
  [[ "$FORCE_REINSTALL" == "1" ]] && return 1
  have "$1" || [[ -x "/usr/local/bin/$1" ]]
}

# =============================================================================
#  SECTION 7 — Step pipeline & result tracking
# =============================================================================
declare -a STEP_NAMES=() STEP_STATES=() STEP_SECS=()
STEP_TOTAL=0
STEP_IDX=0

# run_step "<label>" <function> : run one pipeline stage, time it, record the
# outcome. Convention: rc 0 = OK, rc 3 = SKIP, anything else = FAIL.
run_step() {
  local label="$1"; shift
  STEP_IDX=$(( STEP_IDX + 1 ))
  printf '\n%s%s[%d/%d]%s %s%s%s\n' \
    "$C_BOLD" "$C_CYAN" "$STEP_IDX" "$STEP_TOTAL" "$C_RESET" "$C_BOLD" "$label" "$C_RESET"

  local t0=$SECONDS rc
  "$@"; rc=$?
  local dur=$(( SECONDS - t0 )) state
  case "$rc" in
    0) state="OK";   log_ok   "$label — done ($(fmt_dur "$dur"))" ;;
    3) state="SKIP"; log_warn "$label — skipped" ;;
    *) state="FAIL"; log_error "$label — failed (rc=$rc, see $LOG_FILE)" ;;
  esac
  STEP_NAMES+=("$label"); STEP_STATES+=("$state"); STEP_SECS+=("$dur")
}

# =============================================================================
#  SECTION 8 — User & password setup
# =============================================================================
resolve_user() {
  if [[ -z "$NORMAL_USER" ]]; then
    if   [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then NORMAL_USER="$SUDO_USER"
    elif (( IS_KALI )) && id kali &>/dev/null;                 then NORMAL_USER="kali"
    elif id ubuntu &>/dev/null;                                then NORMAL_USER="ubuntu"
    else                                                            NORMAL_USER="kali"
    fi
    if [[ "${NONINTERACTIVE:-0}" != "1" ]] && have_tty; then
      local _u; read_tty _u "Normal user to configure [${NORMAL_USER}]: "
      NORMAL_USER="${_u:-$NORMAL_USER}"
    fi
  fi

  if ! id "$NORMAL_USER" &>/dev/null; then
    log "User '$NORMAL_USER' not found — creating it."
    useradd -m -s /bin/bash "$NORMAL_USER"
    usermod -aG sudo "$NORMAL_USER" 2>/dev/null || true
  fi
  USER_HOME="$(getent passwd "$NORMAL_USER" | cut -d: -f6)"
  log_ok "Users: root + ${NORMAL_USER} (home: ${USER_HOME})"

  if [[ -z "$SET_PASSWORDS" ]]; then
    if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then SET_PASSWORDS=0
    elif ask_yn "Set/replace passwords for root and ${NORMAL_USER}?" n; then SET_PASSWORDS=1
    else SET_PASSWORDS=0
    fi
  fi
}

setup_passwords() {
  [[ "$SET_PASSWORDS" == "1" ]] || return 3
  [[ "${NONINTERACTIVE:-0}" == "1" ]] && { log_warn "Non-interactive: skipping."; return 3; }
  local u
  for u in root "$NORMAL_USER"; do
    log "New password for '$u':"
    if passwd "$u"; then log_ok "Password updated for $u"; else log_warn "Unchanged for $u"; fi
  done
}

# =============================================================================
#  SECTION 9 — RECON TOOLKIT
#  Each tool is an explicit install function returning: 0 = installed,
#  3 = skipped (already present), non-zero = failed. The TOOLKIT array at the end
#  of this section drives the progress loop and the final report.
# =============================================================================

# ---- Go-based tools ---------------------------------------------------------
tool_ffuf()        { present ffuf        && return 0; go_install_global "github.com/ffuf/ffuf/v2@latest"; }
tool_gau()         { present gau         && return 0; go_install_global "github.com/lc/gau/v2/cmd/gau@latest"; }
tool_hakrawler()   { present hakrawler   && return 0; go_install_global "github.com/hakluke/hakrawler@latest"; }
tool_vhostfinder() { present VhostFinder && return 0; go_install_global "github.com/wdahlenburg/VhostFinder@latest"; }
tool_amass()       { present amass       && return 0; go_install_global "github.com/owasp-amass/amass/v4/...@master"; }

# ---- pipx-based Python tools (isolated environments) ------------------------
_pipx_present() {
  [[ "$FORCE_REINSTALL" == "1" ]] && return 1
  pipx list --short 2>/dev/null | awk '{print $1}' | grep -qx "$1"
}
tool_arjun()     { _pipx_present arjun     && return 0; pipx install --force arjun; }
tool_dirsearch() { _pipx_present dirsearch && return 0; pipx install --force "git+https://github.com/maurosoria/dirsearch.git"; }

# ---- apt-based tools (Kali repo used automatically on Ubuntu) ----------------
_apt_present() { [[ "$FORCE_REINSTALL" == "1" ]] && return 1; dpkg -s "$1" &>/dev/null; }
tool_nmap()    { _apt_present nmap    && return 0; apt_tool nmap; }     # port scanner
tool_massdns() { _apt_present massdns && return 0; apt_tool massdns; }  # shuffledns dependency

# ---- git-cloned tools -------------------------------------------------------
tool_sqlmap() {
  present sqlmap && return 0
  local dir="$TOOLS_DIR/sqlmap"
  clone_tool "https://github.com/sqlmapproject/sqlmap.git" "$dir" || return 1
  make_launcher sqlmap "python3 $dir/sqlmap.py"
}

tool_backupkiller() {
  present backupkiller && return 0
  local dir="$TOOLS_DIR/backupkiller"
  clone_tool "https://github.com/Q0120S/BackupKiller.git" "$dir" || return 1
  run_as "$NORMAL_USER" "cd '$dir' && python3 -m venv .venv && \
    .venv/bin/pip install -q -r requirements.txt" || log_warn "BackupKiller deps had issues"
  make_launcher backupkiller "$dir/.venv/bin/python $dir/fback.py"
}

# ---- Rust-built tool --------------------------------------------------------
tool_x8() {
  present x8 && return 0
  have cargo || [[ -x /root/.cargo/bin/cargo ]] || { log_error "cargo unavailable (Rust stage failed?)"; return 1; }
  local dir="$TOOLS_DIR/x8"
  clone_tool "https://github.com/sh1yo/x8" "$dir" || return 1
  ( cd "$dir" && PATH="/root/.cargo/bin:$PATH" cargo build --release ) || return 1
  install -m 755 "$dir/target/release/x8" /usr/local/bin/x8
}

# ---- Wordlists (large; gated behind INSTALL_SECLISTS) -----------------------
tool_seclists() {
  [[ "$INSTALL_SECLISTS" == "1" ]] || return 3
  if [[ "$FORCE_REINSTALL" != "1" ]] && { dpkg -s seclists &>/dev/null || [[ -d "$TOOLS_DIR/SecLists" ]]; }; then
    return 0
  fi
  apt_tool seclists || clone_tool "https://github.com/danielmiessler/SecLists.git" "$TOOLS_DIR/SecLists"
}

# ---- Toolkit registry: "name|description|function" --------------------------
readonly TOOLKIT=(
  "ffuf|Web fuzzer (paths, vhosts, params)|tool_ffuf"
  "gau|Fetch known URLs (Wayback/OTX/CC)|tool_gau"
  "hakrawler|Fast endpoint-scraping crawler|tool_hakrawler"
  "VhostFinder|Virtual-host discovery|tool_vhostfinder"
  "amass|OWASP subdomain enumeration|tool_amass"
  "arjun|HTTP parameter discovery|tool_arjun"
  "dirsearch|Web path brute-forcer|tool_dirsearch"
  "nmap|Network / port scanner|tool_nmap"
  "massdns|High-perf DNS resolver (shuffledns dep)|tool_massdns"
  "sqlmap|Automatic SQL injection|tool_sqlmap"
  "backupkiller|Backup / bak-file discovery|tool_backupkiller"
  "x8|Hidden parameter discovery (Rust)|tool_x8"
  "seclists|Wordlist collection (~1GB)|tool_seclists"
)

# ProjectDiscovery tools installed by `pdtm -ia` (for the catalogue/report).
readonly PDTM_TOOLS="subfinder httpx nuclei naabu katana dnsx tlsx mapcidr \
asnmap cdncheck interactsh-client notify proxify uncover shuffledns alterx \
chaos-client cloudlist simplehttpserver tldfinder urlfinder vulnx"

# ---- Toolkit stage: iterate the registry with a progress bar ----------------
declare -A TOOL_STATE

draw_bar() {
  (( TTY )) || return 0
  local cur=$1 tot=$2 label=$3 width=26
  local pct=$(( tot > 0 ? cur * 100 / tot : 0 ))
  local fill=$(( tot > 0 ? cur * width / tot : 0 ))
  local bar empty
  printf -v bar   '%*s' "$fill"             ''; bar=${bar// /#}
  printf -v empty '%*s' "$(( width - fill ))" ''; empty=${empty// /-}
  printf '\r  %s[%s%s]%s %3d%%  %s\e[K' "$C_DIM" "$bar" "$empty" "$C_RESET" "$pct" "$label"
}

tool_result_line() {
  local state="$1" name="$2" desc="$3" dur="$4" colour
  case "$state" in OK) colour=$C_GREEN ;; FAIL) colour=$C_RED ;; *) colour=$C_YELLOW ;; esac
  (( TTY )) && printf '\r\e[K'
  printf '  %s%-4s%s %-13s %s%6s%s  %s\n' \
    "$colour" "$state" "$C_RESET" "$name" "$C_DIM" "$(fmt_dur "$dur")" "$C_RESET" "$desc"
}

install_toolkit() {
  [[ "$INSTALL_EXTRA_TOOLS" == "1" ]] || return 3
  [[ "${SKIP_NET:-0}" == "1" ]] && { log_warn "no outbound route — skipping"; return 3; }
  local total=${#TOOLKIT[@]} idx=0 failures=0 entry name desc fn t0 dur rc
  for entry in "${TOOLKIT[@]}"; do
    IFS='|' read -r name desc fn <<<"$entry"
    idx=$(( idx + 1 ))
    draw_bar "$idx" "$total" "installing ${name} ..."

    t0=$SECONDS
    "$fn" >>"$LOG_FILE" 2>&1; rc=$?
    dur=$(( SECONDS - t0 ))

    case "$rc" in
      0) tool_result_line OK   "$name" "$desc" "$dur"; TOOL_STATE[$name]="OK" ;;
      3) tool_result_line SKIP "$name" "$desc" 0;      TOOL_STATE[$name]="SKIP" ;;
      *) tool_result_line FAIL "$name" "$desc" "$dur"; TOOL_STATE[$name]="FAIL"; failures=$(( failures + 1 )) ;;
    esac
  done
  (( TTY )) && printf '\r\e[K'
  [[ $failures -eq 0 ]]
}

# =============================================================================
#  SECTION 10 — DNS resolvers
# -----------------------------------------------------------------------------
#  The box's resolver is often unreliable/filtered in IR (github.com, go.dev,
#  ifconfig.io intermittently fail to resolve). We install a reliable set with
#  Shecan FIRST — Shecan answers sanctioned dev domains (go.dev, etc.) with its
#  own unblocking proxy IPs, which is what actually bypasses the IP-level block
#  from Iran; Cloudflare/Google follow as general fallback.
# =============================================================================
setup_dns() {
  local rc=/etc/resolv.conf
  [[ -e /etc/resolv.conf.provision.bak ]] || cp -a "$rc" /etc/resolv.conf.provision.bak 2>/dev/null || true
  # Detach from a manager-owned symlink so our entries persist during the run.
  [[ -L "$rc" ]] && rm -f "$rc"
  cat >"$rc" <<'EOF'
# Managed by provision.sh
nameserver 178.22.122.100   # Shecan (unblocks go.dev & other sanctioned dev services from IR)
nameserver 185.51.200.2     # Shecan secondary
nameserver 1.1.1.1          # Cloudflare
nameserver 8.8.8.8          # Google
EOF
  chmod 644 "$rc"
  log_ok "DNS set: Shecan (178.22.122.100 / 185.51.200.2) + Cloudflare + Google."
  if getent hosts go.dev >/dev/null 2>&1; then
    log_ok "go.dev resolves."
  else
    log_warn "go.dev not resolving yet (a manager may be rewriting resolv.conf)."
  fi
}

# =============================================================================
#  SECTION 11 — Base system
# =============================================================================
base_setup() {
  _run "apt update" apt-get update -y || return 1
  _run "installing core packages" apt-get install -y \
    curl wget git ca-certificates gnupg lsb-release \
    build-essential pkg-config unzip tar libpcap-dev libssl-dev \
    python3 python3-pip python3-venv pipx \
    software-properties-common apt-transport-https jq || return 1
  pipx ensurepath >/dev/null 2>&1 || true
  install -d -m 0755 "$TOOLS_DIR"
}

# =============================================================================
#  SECTION 12 — Kali repo on Ubuntu (safe apt pinning)
# =============================================================================
setup_kali_repo_on_ubuntu() {
  (( IS_UBUNTU )) || return 3
  local key=/usr/share/keyrings/kali-archive-keyring.gpg
  if [[ ! -f "$key" ]]; then
    _run "importing Kali archive key" \
      bash -c "wget -qO- https://archive.kali.org/archive-key.asc | gpg --dearmor > '$key'" || return 1
  fi
  cat >/etc/apt/sources.list.d/kali.list <<EOF
# Kali rolling — pinned low (see /etc/apt/preferences.d/kali-pin)
deb [signed-by=${key}] http://http.kali.org/kali kali-rolling main contrib non-free non-free-firmware
EOF
  cat >/etc/apt/preferences.d/kali-pin <<'EOF'
# Never let Kali override Ubuntu base packages; pull Kali tools only on demand:
#   apt install -t kali-rolling <package>
Package: *
Pin: release o=Kali
Pin-Priority: 50
EOF
  _run "apt update (with Kali repo)" apt-get update -y || return 1
  log_ok "Kali repo added and pinned (priority 50)."
}

# =============================================================================
#  SECTION 13 — zsh
# =============================================================================
install_zsh() {
  [[ "$INSTALL_ZSH" == "1" ]] || return 3
  have zsh || _run "installing zsh" apt-get install -y zsh zsh-common || return 1
  local zsh_bin; zsh_bin="$(command -v zsh)"

  if [[ ! -f "$USER_HOME/.zshrc" ]]; then
    cat >"$USER_HOME/.zshrc" <<'EOF'
# ---- basic zsh config ----
autoload -Uz compinit && compinit
setopt AUTO_CD HIST_IGNORE_DUPS SHARE_HISTORY
HISTFILE=~/.zsh_history; HISTSIZE=10000; SAVEHIST=10000
PROMPT='%F{green}%n@%m%f:%F{blue}%~%f%# '
EOF
    chown "$NORMAL_USER:$NORMAL_USER" "$USER_HOME/.zshrc"
  fi
  [[ -f /root/.zshrc ]] || cp "$USER_HOME/.zshrc" /root/.zshrc

  chsh -s "$zsh_bin" root           || return 1
  chsh -s "$zsh_bin" "$NORMAL_USER" || return 1
  log_ok "Default shell set to zsh for root and $NORMAL_USER"
}

# =============================================================================
#  SECTION 14 — Go toolchain
# =============================================================================
install_go() {
  [[ "$INSTALL_GO" == "1" ]] || return 3
  [[ "${SKIP_NET:-0}" == "1" ]] && { log_warn "no outbound route — skipping"; return 3; }

  local want="$GO_VERSION"
  [[ -z "$want" ]] && want="$(curl -fsSL https://go.dev/VERSION?m=text | head -n1)"
  [[ -n "$want" ]] || { log_error "Could not determine Go version"; return 1; }

  if [[ -x /usr/local/go/bin/go ]] && [[ "$(/usr/local/go/bin/go version 2>/dev/null | awk '{print $3}')" == "$want" ]]; then
    log_ok "Go $want already installed"
  else
    local tgz="${want}.linux-${GOARCH}.tar.gz"
    _run "downloading $tgz" curl -fsSL --retry 3 --retry-delay 2 "https://go.dev/dl/${tgz}" -o "/tmp/${tgz}" || return 1
    _run "extracting Go into /usr/local" \
      bash -c "rm -rf /usr/local/go && tar -C /usr/local -xzf '/tmp/${tgz}' && rm -f '/tmp/${tgz}'" || return 1
  fi

  # System-wide Go env for bash login shells.
  cat >/etc/profile.d/go.sh <<'EOF'
export GOROOT=/usr/local/go
export GOPATH="$HOME/go"
export PATH="$GOROOT/bin:$GOPATH/bin:$HOME/.pdtm/go/bin:/usr/local/bin:$PATH"
export GOPROXY=https://proxy.golang.org,direct
export GOSUMDB=off
EOF
  chmod 644 /etc/profile.d/go.sh

  # Mirror it into zsh's env file (read by every zsh session).
  install -d -m 0755 /etc/zsh
  if ! grep -q 'System-wide Go' /etc/zsh/zshenv 2>/dev/null; then
    cat >>/etc/zsh/zshenv <<'EOF'
# System-wide Go
export GOROOT=/usr/local/go
export GOPATH="$HOME/go"
export PATH="$GOROOT/bin:$GOPATH/bin:$HOME/.pdtm/go/bin:/usr/local/bin:$PATH"
export GOPROXY=https://proxy.golang.org,direct
export GOSUMDB=off
EOF
  fi

  # Make Go usable for the REST of this process too — profile.d/zshenv only
  # affect new shells, but pdtm's guard and other stages run in THIS process.
  export GOROOT=/usr/local/go
  export GOPATH="${GOPATH:-/root/go}"
  export PATH="/usr/local/go/bin:/usr/local/bin:$GOPATH/bin:$PATH"
  export GOPROXY="${GOPROXY:-https://proxy.golang.org,direct}" GOSUMDB="${GOSUMDB:-off}"

  /usr/local/go/bin/go version >>"$LOG_FILE" 2>&1 || return 1
  log_ok "Go ready: $(/usr/local/go/bin/go version | awk '{print $3}')"
}

# =============================================================================
#  SECTION 15 — Rust toolchain (rustup, apt fallback for filtered networks)
# =============================================================================
install_rust() {
  [[ "$INSTALL_RUST" == "1" ]] || return 3
  if have cargo; then log_ok "Rust/cargo already present"; return 0; fi

  # sh.rustup.rs is often filtered (connection reset); fall back to apt packages.
  if curl -fsSL --retry 2 --connect-timeout 15 https://sh.rustup.rs -o /tmp/rustup-init.sh 2>/dev/null; then
    _run "installing rustup" sh /tmp/rustup-init.sh -y --no-modify-path || true
    rm -f /tmp/rustup-init.sh
    # shellcheck disable=SC1091
    [[ -f /root/.cargo/env ]] && source /root/.cargo/env
  else
    log_warn "sh.rustup.rs unreachable — using apt rustc/cargo"
  fi

  if ! have cargo && [[ ! -x /root/.cargo/bin/cargo ]]; then
    _run "installing rustc/cargo from apt" apt-get install -y rustc cargo || return 1
  fi

  cat >/etc/profile.d/rust.sh <<'EOF'
export PATH="$HOME/.cargo/bin:/root/.cargo/bin:$PATH"
EOF
  chmod 644 /etc/profile.d/rust.sh
  install -d -m 0755 /root/.cargo
  [[ -f /root/.cargo/config.toml ]] || printf '[net]\ngit-fetch-with-cli = true\n' >/root/.cargo/config.toml

  { have cargo && cargo --version; } >>"$LOG_FILE" 2>&1 \
    || /root/.cargo/bin/cargo --version >>"$LOG_FILE" 2>&1 || return 1
  log_ok "Rust ready"
}

# =============================================================================
#  SECTION 16 — ProjectDiscovery pdtm + tools + nuclei templates
# =============================================================================
install_pdtm() {
  [[ "$INSTALL_PDTM" == "1" ]] || return 3
  [[ "${SKIP_NET:-0}" == "1" ]] && { log_warn "no outbound route — skipping"; return 3; }
  have go || [[ -x /usr/local/go/bin/go ]] || { log_error "Go is required for pdtm"; return 1; }

  if [[ "$FORCE_REINSTALL" == "1" ]] || ! have pdtm; then
    _run "installing pdtm" go_install_global "github.com/projectdiscovery/pdtm/cmd/pdtm@latest" || return 1
  fi

  local users=("$NORMAL_USER")
  [[ "$PDTM_FOR_ROOT" == "1" ]] && users=("root" "$NORMAL_USER")

  local u uhome
  for u in "${users[@]}"; do
    # pdtm/nuclei write into ~/.config and ~/.pdtm; make sure the target user
    # owns those (a previous root run can leave them root-owned -> "permission
    # denied"). Create and chown them before running as that user.
    uhome="$(getent passwd "$u" | cut -d: -f6)"
    if [[ -n "$uhome" ]]; then
      install -d -o "$u" -g "$u" "$uhome/.config" "$uhome/.pdtm" 2>/dev/null || true
      chown -R "$u":"$u" "$uhome/.config" "$uhome/.pdtm" 2>/dev/null || true
    fi
    _run "installing all PD tools for $u" run_as "$u" "pdtm -ia -duc" \
      || log_warn "pdtm -ia reported issues for $u"
    _run "updating nuclei templates for $u" run_as "$u" "nuclei -update-templates -duc" \
      || log_warn "nuclei template update issue for $u"
  done
}

# =============================================================================
#  SECTION 17 — v2ray core + v2rayA GUI
# =============================================================================
install_v2ray() {
  [[ "$INSTALL_V2RAY" == "1" ]] || return 3
  if have v2ray; then log_ok "v2ray already installed"; return 0; fi

  # Fetch the official installer, preferring the jsDelivr mirror (reachable in
  # filtered regions) and falling back to raw.githubusercontent.com.
  local s; s="$(mktemp)"
  _run "fetching v2ray installer" bash -c "
    curl -fsSL --retry 3 --retry-delay 2 'https://cdn.jsdelivr.net/gh/v2fly/fhs-install-v2ray@master/install-release.sh' -o '$s' \
    || curl -fsSL --retry 3 --retry-delay 2 'https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh' -o '$s'" \
    || { rm -f "$s"; return 1; }
  _run "installing v2ray core" bash "$s" || { rm -f "$s"; return 1; }
  rm -f "$s"
}

install_v2raya() {
  [[ "$INSTALL_V2RAYA" == "1" ]] || return 3
  if have v2raya; then
    log_ok "v2rayA already installed"
  else
    # v2rayA's site / apt repo is often filtered; pull the .deb from GitHub.
    local va_arch url deb
    case "$GOARCH" in amd64) va_arch="x64" ;; arm64) va_arch="arm64" ;; *) va_arch="$GOARCH" ;; esac

    url="$(curl -fsSL https://api.github.com/repos/v2rayA/v2rayA/releases/latest \
          | jq -r --arg a "$va_arch" \
            '.assets[] | select(.name | test("installer_debian_" + $a + "_.*\\.deb$")) | .browser_download_url' \
          | head -n1)"
    [[ -n "$url" && "$url" != "null" ]] || { log_error "No v2rayA .deb for arch '$va_arch'"; return 1; }

    deb="/tmp/$(basename "$url")"
    _run "downloading v2rayA ($(basename "$url"))" curl -fL --retry 3 --retry-delay 2 "$url" -o "$deb" || return 1
    _run "installing v2rayA" \
      bash -c "apt-get install -y '$deb' || { dpkg -i '$deb'; apt-get -f install -y; }" || return 1
    rm -f "$deb"
  fi

  systemctl enable v2raya >/dev/null 2>&1 || true
  systemctl start  v2raya >/dev/null 2>&1 || true
  log_ok "v2rayA running — open http://<server-ip>:2017 to import your config"
  log    "   Then: TProxy mode → Start → verify with: curl ifconfig.io"
}

# =============================================================================
#  SECTION 18 — Network location gate
# -----------------------------------------------------------------------------
#  go.dev (and rustup / crates.io / raw.githubusercontent) are filtered from
#  Iran. Two conditions decide whether we may continue to the network-heavy
#  stages:
#    * Go already installed  -> proceed regardless of location (the Go module
#      mirror works from IR).
#    * Go NOT installed      -> the exit IP must be outside IR, or those stages
#      will certainly fail. We loop, guiding the user to enable the proxy, and
#      re-check until the country is no longer IR (or the user aborts).
# =============================================================================
current_country() {
  curl -fsS --max-time 15 https://ifconfig.io/country_code 2>/dev/null | tr -d '[:space:]'
}

# The decisive signal: can we actually reach go.dev? With Shecan DNS this can be
# true even from an Iranian IP, so we test reachability rather than location.
go_reachable() {
  curl -fsS --max-time 12 -o /dev/null "https://go.dev/VERSION?m=text" 2>/dev/null
}

print_proxy_instructions() {
  local ip; ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  printf '\n%s%sAction required — make go.dev reachable%s\n' "$C_BOLD" "$C_YELLOW" "$C_RESET"
  cat <<EOF
go.dev (and other tool sources) are blocked from Iran, so installation cannot
continue until this machine can reach them. Shecan DNS is already configured and
usually unblocks go.dev on its own — but if it is still unreachable, bring up the
proxy (v2ray/v2rayA are already installed):

  1. From a device that can reach this server, open:  http://${ip:-<server-ip>}:2017
  2. Create the v2rayA admin account (first visit only).
  3. Import your v2ray config (paste a vmess:// / vless:// link or a subscription URL).
  4. Select the imported node and click "Connect".
  5. Open Settings and set the proxy mode to "TProxy" (transparent proxy) so the
     whole system — including this installer — is routed through it.
  6. Confirm the status shows the proxy is running.

EOF
}

connectivity_gate() {
  # Go already present → nothing to check.
  if have go || [[ -x /usr/local/go/bin/go ]]; then
    log_ok "Go already installed — reachability check not required."
    return 0
  fi

  # If go.dev is reachable (via Shecan DNS or a proxy), proceed regardless of IP.
  if go_reachable; then
    log_ok "go.dev is reachable — continuing."
    return 0
  fi

  local cc; cc="$(current_country)"
  log "go.dev is not reachable (exit country: ${cc:-unknown})."
  print_proxy_instructions
  if ! have_tty; then
    log_error "go.dev unreachable and no terminal to confirm — cannot continue."
    SKIP_NET=1
    return 1
  fi

  local ans
  while true; do
    read_tty ans "Made go.dev reachable (DNS or TProxy)? type 'yes' to re-check, or 'skip' to abort: "
    case "${ans,,}" in
      skip|abort|quit|q)
        log_warn "Skipping the network-dependent stages (go.dev unreachable)."
        SKIP_NET=1
        return 1 ;;
    esac
    if go_reachable; then
      log_ok "go.dev is now reachable — continuing."
      return 0
    fi
    cc="$(current_country)"
    log_warn "Still unreachable (country: ${cc:-unknown}). Ensure Shecan DNS is active or the proxy is ON (TProxy)."
  done
}

# =============================================================================
#  SECTION 19 — Catalogue (--list-tools) & final report
# =============================================================================
list_tools() {
  printf '\n%s%sTool catalogue%s  (%s v%s)\n\n' \
    "$C_BOLD" "$C_CYAN" "$C_RESET" "$SCRIPT_NAME" "$SCRIPT_VERSION"
  printf '%sExtra recon toolkit (%d)%s\n' "$C_BOLD" "${#TOOLKIT[@]}" "$C_RESET"
  local entry name desc _fn
  for entry in "${TOOLKIT[@]}"; do
    IFS='|' read -r name desc _fn <<<"$entry"
    printf '  %-13s %s\n' "$name" "$desc"
  done
  printf '\n%sProjectDiscovery suite (via pdtm -ia)%s\n  ' "$C_BOLD" "$C_RESET"
  # shellcheck disable=SC2086  # intentional: split the list into separate args
  printf '%s ' $PDTM_TOOLS; printf '\n\n'
}

# True if a ProjectDiscovery tool is actually present (root or user pdtm bin,
# or anywhere on PATH).
pd_present() {
  local t="$1"
  [[ -x "/root/.pdtm/go/bin/$t" ]] && return 0
  [[ -n "${USER_HOME:-}" && -x "$USER_HOME/.pdtm/go/bin/$t" ]] && return 0
  command -v "$t" >/dev/null 2>&1
}

print_report() {
  local total_dur=$(( SECONDS - SCRIPT_START ))
  printf '\n%s%s══════════════ PROVISIONING SUMMARY ══════════════%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
  printf '  %-22s %s\n' "Host"       "$OS_NAME ($GOARCH)"
  printf '  %-22s %s\n' "User"       "$NORMAL_USER"
  printf '  %-22s %s\n' "Total time" "$(fmt_dur "$total_dur")"
  printf '  %-22s %s\n' "Log file"   "$LOG_FILE"

  printf '\n  %sStages%s\n' "$C_BOLD" "$C_RESET"
  local i colour
  for i in "${!STEP_NAMES[@]}"; do
    case "${STEP_STATES[$i]}" in OK) colour=$C_GREEN ;; FAIL) colour=$C_RED ;; *) colour=$C_YELLOW ;; esac
    printf '    %s%-4s%s %-30s %s%s%s\n' \
      "$colour" "${STEP_STATES[$i]}" "$C_RESET" "${STEP_NAMES[$i]}" \
      "$C_DIM" "$(fmt_dur "${STEP_SECS[$i]}")" "$C_RESET"
  done

  if [[ ${#TOOL_STATE[@]} -gt 0 ]]; then
    printf '\n  %sRecon toolkit%s\n' "$C_BOLD" "$C_RESET"
    local entry name desc _fn word
    for entry in "${TOOLKIT[@]}"; do
      IFS='|' read -r name desc _fn <<<"$entry"
      case "${TOOL_STATE[$name]:-}" in
        OK)   colour=$C_GREEN;  word="installed" ;;
        FAIL) colour=$C_RED;    word="failed" ;;
        SKIP) colour=$C_YELLOW; word="skipped" ;;
        *)    colour=$C_DIM;    word="not run" ;;
      esac
      printf '    %s%-9s%s %-13s %s\n' "$colour" "$word" "$C_RESET" "$name" "$desc"
    done
  fi

  # Full ProjectDiscovery suite with each tool's actual presence.
  if [[ "$INSTALL_PDTM" == "1" ]]; then
    printf '\n  %sProjectDiscovery tools%s\n' "$C_BOLD" "$C_RESET"
    local t
    # shellcheck disable=SC2086  # intentional word-splitting of the tool list
    for t in $PDTM_TOOLS; do
      if pd_present "$t"; then colour=$C_GREEN; word="installed"; else colour=$C_RED; word="missing"; fi
      printf '    %s%-9s%s %s\n' "$colour" "$word" "$C_RESET" "$t"
    done
  fi

  printf '\n%s%s══════════════════════════════════════════════════%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET"
  log "Run 'exec zsh' or re-login to load the new shell & PATH."
}

# =============================================================================
#  SECTION 20 — Pipeline definition & main
# =============================================================================
# Pipeline stages, in execution order — "Label|function".
# v2ray/v2rayA come before the network gate so the user can route traffic out
# of Iran (where go.dev is filtered) before the Go/Rust/PD stages run.
readonly PIPELINE=(
  "DNS resolvers|setup_dns"
  "Passwords (root + user)|setup_passwords"
  "Base system + core packages|base_setup"
  "Kali repo on Ubuntu|setup_kali_repo_on_ubuntu"
  "zsh + default shell|install_zsh"
  "v2ray core|install_v2ray"
  "v2rayA GUI|install_v2raya"
  "Network location gate|connectivity_gate"
  "Go toolchain|install_go"
  "Rust toolchain|install_rust"
  "ProjectDiscovery pdtm + tools|install_pdtm"
  "Extra recon toolkit|install_toolkit"
)

cleanup() { (( TTY )) && tput cnorm 2>/dev/null; return 0; }
trap cleanup EXIT
trap 'echo; log_error "Interrupted."; exit 130' INT TERM

main() {
  SCRIPT_START=$SECONDS
  parse_args "$@"

  # --list-tools does not require root.
  if (( DO_LIST_TOOLS )); then list_tools; exit 0; fi

  if ! is_root; then
    if [[ -r "$0" && "$0" != "bash" && "$0" != "-bash" ]]; then
      log_warn "Not root — re-executing with sudo…"
      exec sudo -E bash "$0" "$@"
    fi
    log_error "This script must run as root."
    log_error "Piped install:  curl -fsSL <url>/install.sh | bash"
    exit 1
  fi

  # Set up the log file now that we are root.
  LOG_FILE="/var/log/provision-$(date +%Y%m%d-%H%M%S).log"
  : >"$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/provision-$(date +%Y%m%d-%H%M%S).log"
  printf '%s%s v%s%s — %s\n' "$C_BOLD" "$SCRIPT_NAME" "$SCRIPT_VERSION" "$C_RESET" "$(date)"
  log "Full logs: $LOG_FILE"

  detect_os
  resolve_user

  # If Go persists from a previous run, make it visible to every stage now
  # (install_go re-exports after a fresh install; this covers the skip case).
  if [[ -x /usr/local/go/bin/go ]]; then
    export GOROOT=/usr/local/go GOPATH="${GOPATH:-/root/go}"
    export PATH="/usr/local/go/bin:/usr/local/bin:$GOPATH/bin:$PATH"
  fi

  STEP_TOTAL=${#PIPELINE[@]}
  local entry
  for entry in "${PIPELINE[@]}"; do
    run_step "${entry%%|*}" "${entry#*|}"
  done

  print_report
}

main "$@"
