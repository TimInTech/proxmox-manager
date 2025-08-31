#!/usr/bin/env bash
# install_dependencies.sh
# Purpose: Install minimal runtime dependencies for proxmox-manager.sh on a Proxmox host
# Tested on Proxmox VE 8 (Debian bookworm) & 9 (Debian trixie)

set -Eeuo pipefail

RED="\033[1;31m"; GREEN="\033[1;32m"; YELLOW="\033[1;33m"; CYAN="\033[1;36m"; NC="\033[0m"

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo -e "${RED}Please run as root (sudo -i).${NC}"
    exit 1
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

need_root

echo -e "${CYAN}==> Detecting system & Proxmox version…${NC}"
if have pveversion; then
  echo -e "Proxmox: $(pveversion || true)"
else
  echo -e "${YELLOW}Note: 'pveversion' not found. Is this really a Proxmox host?${NC}"
fi

echo -e "${CYAN}==> Running apt update…${NC}"
apt-get update -y

# Core packages (most are preinstalled on Debian/Proxmox, but ensure they exist)
PKGS=(
  bash coreutils grep sed gawk procps
  curl git
  jq            # useful for future JSON handling
  shellcheck    # optional, for linting shell scripts
)

echo -e "${CYAN}==> Installing/ensuring packages:${NC} ${PKGS[*]}"
apt-get install -y "${PKGS[@]}"

# Proxmox CLI tools
MISSING_PVE=0
if ! have qm; then
  echo -e "${YELLOW}Warning: 'qm' not found. (Normal if not running on Proxmox VE)${NC}"
  MISSING_PVE=1
fi
if ! have pct; then
  echo -e "${YELLOW}Warning: 'pct' not found. (Normal if not running on Proxmox VE)${NC}"
  MISSING_PVE=1
fi

# Summary
echo -e "${GREEN}==> Done.${NC}"
echo -e "Installed and available binaries:"
for c in bash qm pct awk sed grep curl git jq shellcheck; do
  if have "$c"; then
    echo -e "  • ${c}: $( ( "$c" --version 2>/dev/null || "$c" -V 2>/dev/null || true ) | head -n1 )"
  else
    echo -e "  • ${c}: ${RED}MISSING${NC}"
  fi
done

if (( MISSING_PVE )); then
  echo -e "${YELLOW}Note:${NC} Without 'qm' and 'pct' some script functions will be disabled."
fi

echo -e "${GREEN}System ready. You can now run './proxmox-manager.sh'.${NC}"

