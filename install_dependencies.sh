#!/usr/bin/env bash
# install_dependencies.sh — install optional helpers and global pman command for proxmox-manager
# Idempotent install script for Debian/Proxmox VE nodes.
#
# Optional packages installed:
#   curl        — general HTTP client
#   git         — version control
#   sc-shellcheck — Bash static analysis (CI/dev)
#   virt-viewer — SPICE/VNC viewer (for --spice workflow)
#   jq          — JSON processor (for --json output)

set -euo pipefail

# ---------------------------------------------------------------------------
# Root check — must run as root to install system packages
# ---------------------------------------------------------------------------
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  printf 'Error: %s must be run as root.\n' "$(basename "$0")" >&2
  printf 'Try: sudo %s\n' "$0" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
_log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
_ok()  { printf '[%s] OK: %s\n' "$(date '+%H:%M:%S')" "$*"; }
_err() { printf '[%s] Error: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }

# ---------------------------------------------------------------------------
# Detect package manager
# ---------------------------------------------------------------------------
if ! command -v apt-get >/dev/null 2>&1; then
  _err "apt-get not found. This script requires a Debian-based system."
  exit 1
fi

# ---------------------------------------------------------------------------
# Check which packages are already installed
# ---------------------------------------------------------------------------
PKGS=(curl git shellcheck virt-viewer jq)
MISSING=()

for pkg in "${PKGS[@]}"; do
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    _log "Already installed: $pkg"
  else
    _log "Will install: $pkg"
    MISSING+=("$pkg")
  fi
done

# ---------------------------------------------------------------------------
# Install missing packages
# ---------------------------------------------------------------------------
if [[ "${#MISSING[@]}" -eq 0 ]]; then
  _ok "All optional packages are already installed."
else
  _log "Updating package lists..."
  if ! apt-get update -qq; then
    _err "apt-get update failed. Check your network connection or /etc/apt/sources.list."
    exit 1
  fi

  _log "Installing: ${MISSING[*]}"
  if ! apt-get install -y "${MISSING[@]}"; then
    _err "Package installation failed for: ${MISSING[*]}"
    exit 1
  fi
  _ok "Installed: ${MISSING[*]}"
fi

# ---------------------------------------------------------------------------
# Install pman — root-owned copy in /usr/local/bin
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PMAN_SRC="${SCRIPT_DIR}/proxmox-manager.sh"
PMAN_DIR="/usr/local/bin"
PMAN_DST="/usr/local/bin/pman"

if [[ ! -f "$PMAN_SRC" ]]; then
  _err "proxmox-manager.sh not found at ${PMAN_SRC}. Run install_dependencies.sh from the repo root."
  exit 1
fi

if [[ ! -d "$PMAN_DIR" || -L "$PMAN_DIR" ]]; then
  _err "${PMAN_DIR} must be an existing regular directory."
  exit 1
fi

PMAN_DIR_OWNER="$(stat -Lc '%u' -- "$PMAN_DIR" 2>/dev/null || printf 'invalid')"
PMAN_DIR_MODE="$(stat -Lc '%a' -- "$PMAN_DIR" 2>/dev/null || printf 'invalid')"
if [[ "$PMAN_DIR_OWNER" != "0" || ! "$PMAN_DIR_MODE" =~ ^[0-7]{3,4}$ ]] || ((8#$PMAN_DIR_MODE & 8#022)); then
  _err "${PMAN_DIR} must be root-owned and not group/world-writable."
  exit 1
fi

PMAN_TMP="$(mktemp -p "$PMAN_DIR" '.pman.XXXXXX')" || {
  _err "Could not create a temporary install file in ${PMAN_DIR}."
  exit 1
}

if ! install -o root -g root -m 0755 "$PMAN_SRC" "$PMAN_TMP" || ! cmp -s "$PMAN_SRC" "$PMAN_TMP"; then
  rm -f -- "$PMAN_TMP"
  _err "Failed to stage a verified pman executable."
  exit 1
fi
if ! mv -fT -- "$PMAN_TMP" "$PMAN_DST"; then
  rm -f -- "$PMAN_TMP"
  _err "Failed to install ${PMAN_DST}."
  exit 1
fi
_ok "Installed root-owned executable: ${PMAN_DST}"

_ok "Done. All optional dependencies are available. Run 'pman' to start."
