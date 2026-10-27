#!/usr/bin/env bash
# Build matching core and optional-module assets without executing module actions.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="${1:-$root/dist}"
mkdir -p -- "$output"
output=$(cd "$output" && pwd)
version=$(bash "$root/proxmox-manager.sh" --version | awk '{print $2}')
cp -- "$root/proxmox-manager.sh" "$output/proxmox-manager.sh"
cp -- "$root/install_dependencies.sh" "$output/install_dependencies.sh"
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
  --exclude=__pycache__ --exclude='*.pyc' -czf "$output/pman-maintenance-v$version.tar.gz" \
  -C "$root" proxmox-manager.sh install_dependencies.sh LICENSE docs/maintenance.md maintenance
(
  cd "$output"
  sha256sum proxmox-manager.sh install_dependencies.sh "pman-maintenance-v$version.tar.gz" >SHA256SUMS
)
printf 'Release assets: %s\n' "$output"
