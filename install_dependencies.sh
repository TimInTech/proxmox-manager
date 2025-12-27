#!/usr/bin/env bash
# install_dependencies.sh - install optional helpers for proxmox-manager
# Idempotent install script for Debian/Proxmox nodes

set -Eeuo pipefail
IFS=$'\n\t'

log() { printf '%s\n' "$1"; }
err() { printf '%s\n' "$1" >&2; }

confirm() {
  local prompt="$1"
  local reply

  if [[ "${PROXMOX_MANAGER_ASSUME_YES:-0}" == "1" ]]; then
    return 0
  fi

  if [[ ! -t 0 ]]; then
    err "No TTY available for confirmation: $prompt"
    return 1
  fi

  printf '%s' "$prompt"
  read -r reply
  [[ "$reply" =~ ^[yYjJ]$ ]]
}

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  err "Please run as root."
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  err "apt-get not found. This installer supports Debian/Proxmox only."
  exit 1
fi

if ! command -v dpkg >/dev/null 2>&1; then
  err "dpkg not found. This installer supports Debian/Proxmox only."
  exit 1
fi

PKGS=(curl git shellcheck virt-viewer jq)
MISSING=()
for pkg in "${PKGS[@]}"; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    MISSING+=("$pkg")
  fi
done

if ((${#MISSING[@]})); then
  if ! confirm "Install missing packages: ${MISSING[*]}? (y/N): "; then
    err "Aborted."
    exit 1
  fi
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
