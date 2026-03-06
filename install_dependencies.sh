#!/usr/bin/env bash
# install_dependencies.sh — install optional helpers for proxmox-manager
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

_ok "Done. All optional dependencies are available."
