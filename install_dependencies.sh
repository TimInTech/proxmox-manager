#!/usr/bin/env bash
# install_dependencies.sh - install optional helpers for proxmox-manager
# Idempotent install script for Debian/Proxmox nodes

set -euo pipefail

log() { echo -e "$1"; }
err() { echo -e "$1" >&2; }

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  err "Please run as root."
  exit 1
fi

PKGS=(curl git shellcheck virt-viewer jq)
MISSING=()
for pkg in "${PKGS[@]}"; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    MISSING+=("$pkg")
  fi
done

if (( ${#MISSING[@]} )); then
  log "Updating package lists..."
  if ! apt-get update; then
    err "apt-get update failed"
    exit 1
  fi
  log "Installing packages: ${MISSING[*]}"
  if ! apt-get install -y "${MISSING[@]}"; then
    err "Package installation failed"
    exit 1
  fi
else
  log "All packages already installed."
fi

log "Done."
