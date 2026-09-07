#!/usr/bin/env bash
# =============================================================================
#  install.sh — one-line bootstrapper for provision.sh
# -----------------------------------------------------------------------------
#  Downloads provision.sh, elevates to root, and runs it with the terminal
#  reconnected so interactive prompts work even over a pipe.
#
#  Usage:
#    curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/main/install.sh | bash
#
#  Any arguments after `bash -s --` are forwarded to provision.sh, e.g.:
#    curl -fsSL .../install.sh | bash -s -- --user hunter --force
#
#  Override the source (e.g. a fork or a pinned tag):
#    PROVISION_URL=https://.../provision.sh curl -fsSL .../install.sh | bash
# =============================================================================
set -euo pipefail

PROVISION_URL="${PROVISION_URL:-https://raw.githubusercontent.com/<you>/<repo>/main/provision.sh}"

c_err=$'\e[31m'; c_inf=$'\e[34m'; c_ok=$'\e[32m'; c_rst=$'\e[0m'
err() { printf '%s[-]%s %s\n' "$c_err" "$c_rst" "$*" >&2; }
inf() { printf '%s[*]%s %s\n' "$c_inf" "$c_rst" "$*"; }
ok()  { printf '%s[+]%s %s\n' "$c_ok"  "$c_rst" "$*"; }

command -v curl >/dev/null 2>&1 || { err "curl is required."; exit 1; }

tmp="$(mktemp "${TMPDIR:-/tmp}/provision.XXXXXX.sh")"
trap 'rm -f "$tmp"' EXIT

inf "Downloading provision.sh …"
curl -fsSL "$PROVISION_URL" -o "$tmp"
[[ -s "$tmp" ]] || { err "Download failed or empty file."; exit 1; }
chmod +x "$tmp"
ok "Downloaded ($(wc -c <"$tmp") bytes)."

# Elevate if needed.
if [[ "$(id -u)" -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || { err "Run as root, or install sudo."; exit 1; }
  inf "Elevating with sudo …"
fi

# Run provision.sh with stdin attached to the real terminal when we have one,
# so its prompts work; otherwise attach /dev/null for safe non-interactive runs.
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
