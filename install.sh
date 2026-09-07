#!/usr/bin/env bash
# =============================================================================
#  install.sh — one-line bootstrapper for provision.sh
# -----------------------------------------------------------------------------
#  Downloads provision.sh (trying several mirrors, with retries), elevates to
#  root, and runs it with the terminal reconnected so interactive prompts work
#  even over a pipe.
#
#  Usage (recommended for filtered networks — jsDelivr mirror):
#    curl -fsSL https://cdn.jsdelivr.net/gh/mojtaba13133/bootstrapper@main/install.sh | bash
#
#  Or from GitHub raw:
#    curl -fsSL https://raw.githubusercontent.com/mojtaba13133/bootstrapper/main/install.sh | bash
#
#  Forward arguments to provision.sh with `-s --`:
#    curl -fsSL <installer-url> | bash -s -- --user hunter --force
#
#  Overrides (env):
#    REPO=mojtaba13133/bootstrapper   BRANCH=main   PROVISION_URL=<direct url to provision.sh>
# =============================================================================
set -euo pipefail

# Point these at your fork; override via env without editing the file.
REPO="${REPO:-mojtaba13133/bootstrapper}"
BRANCH="${BRANCH:-main}"

# Mirrors for provision.sh, tried in order. jsDelivr is a GitHub CDN that stays
# reachable in many regions where raw.githubusercontent.com is filtered, so it
# goes first. An explicit PROVISION_URL overrides everything.
MIRRORS=()
[[ -n "${PROVISION_URL:-}" ]] && MIRRORS+=("$PROVISION_URL")
MIRRORS+=(
  "https://cdn.jsdelivr.net/gh/${REPO}@${BRANCH}/provision.sh"
  "https://raw.githubusercontent.com/${REPO}/${BRANCH}/provision.sh"
)

c_err=$'\e[31m'; c_inf=$'\e[34m'; c_ok=$'\e[32m'; c_warn=$'\e[33m'; c_rst=$'\e[0m'
err()  { printf '%s[-]%s %s\n' "$c_err"  "$c_rst" "$*" >&2; }
inf()  { printf '%s[*]%s %s\n' "$c_inf"  "$c_rst" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$c_ok"   "$c_rst" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_warn" "$c_rst" "$*"; }

command -v curl >/dev/null 2>&1 || { err "curl is required."; exit 1; }

tmp="$(mktemp "${TMPDIR:-/tmp}/provision.XXXXXX.sh")"
trap 'rm -f "$tmp"' EXIT

# Try each mirror with retries; keep the first non-empty download.
download() {
  local url
  for url in "${MIRRORS[@]}"; do
    [[ -n "$url" ]] || continue
    inf "Downloading provision.sh from ${url#https://} …"
    if curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 "$url" -o "$tmp" && [[ -s "$tmp" ]]; then
      ok "Downloaded ($(wc -c <"$tmp") bytes)."
      return 0
    fi
    warn "mirror unreachable — trying next…"
  done
  err "Could not download provision.sh from any mirror."
  err "Set REPO=mojtaba13133/bootstrapper (and BRANCH), or PROVISION_URL=<direct-url>, and retry."
  return 1
}
download || exit 1
chmod +x "$tmp"

if [[ "$(id -u)" -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || { err "Run as root, or install sudo."; exit 1; }
  inf "Elevating with sudo …"
fi

# Run provision.sh; attach the real terminal when we have one so prompts work.
invoke() {
  if [[ "$(id -u)" -eq 0 ]]; then bash "$tmp" "$@"; else sudo -E bash "$tmp" "$@"; fi
}
# `-r /dev/tty` is unreliable (the node can exist but be unopenable), so probe.
have_tty() { (exec </dev/tty) 2>/dev/null; }

rc=0
if have_tty; then
  invoke "$@" </dev/tty || rc=$?
else
  invoke "$@" </dev/null || rc=$?
fi
exit "$rc"
