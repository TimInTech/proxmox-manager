#!/usr/bin/env bash
# =============================================================================
# Deterministic Headless Pipeline for Proxmox Manager GIF/Video Demo
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "${SCRIPT_DIR}/build_demo.py" "$@"
