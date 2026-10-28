#!/usr/bin/env bash
# Install pman core and optionally its independent maintenance package.
set -euo pipefail
umask 022
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
WITH_MAINTENANCE=auto
TIMER=auto
ACTION=install
DESTDIR=''
usage() {
  cat <<'EOF'
Usage: ./install_dependencies.sh [--with-maintenance|--without-maintenance]
       [--no-source-timer] [--uninstall-maintenance|--rollback-maintenance]
       [--destdir DIRECTORY]
No package installation is performed. --destdir stages files only (no services).
EOF
}
while (($#)); do
  case "$1" in
  --with-maintenance) WITH_MAINTENANCE=yes ;;
  --without-maintenance) WITH_MAINTENANCE=no ;;
  --no-source-timer) TIMER=0 ;;
  --uninstall-maintenance) ACTION=uninstall ;;
  --rollback-maintenance) ACTION=rollback ;;
  --destdir)
    (($# >= 2)) || {
      usage
      exit 2
    }
    DESTDIR="$2"
    if [[ "$DESTDIR" != /* || "$DESTDIR" == / || "$DESTDIR" != "$(realpath -m -- "$DESTDIR")" ]]; then
      echo 'Use a normalized absolute staging directory, not / or a path alias.' >&2
      exit 2
    fi
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage
    exit 2
    ;;
  esac
  shift
done
if [[ -z "$DESTDIR" && "${EUID:-$(id -u)}" != 0 ]]; then
  echo 'Run as root on the Proxmox host, or use --destdir for staging.' >&2
  exit 1
fi
if [[ -z "$DESTDIR" ]] && ! command -v pveversion >/dev/null 2>&1; then
  echo 'No Proxmox VE host detected.' >&2
  exit 1
fi
# Validate every installation parent before writing, including existing staging paths.
secure_dir() {
  local path="$1" owner mode
  [[ "$path" == / ]] || secure_dir "$(dirname -- "$path")"
  if [[ ! -e "$path" && ! -L "$path" ]]; then
    mkdir -- "$path"
  fi
  [[ -d "$path" && ! -L "$path" ]] || {
    echo "Unsafe directory: $path" >&2
    exit 1
  }
  if [[ -z "$DESTDIR" ]]; then
    owner=$(stat -Lc %u -- "$path")
    mode=$(stat -Lc %a -- "$path")
    if [[ "$owner" != 0 || ! "$mode" =~ ^[0-7]{3,4}$ ]] || (((8#$mode & 8#022) != 0)); then
      echo "Unsafe permissions: $path" >&2
      exit 1
    fi
  fi
}

base="$DESTDIR/usr/local/lib/pman/maintenance"
bin="$DESTDIR/usr/local/bin"
units="$DESTDIR/etc/systemd/system"
# Validate all destination chains before any install, rollback or removal.
secure_dir "$bin"
secure_dir "$units"
secure_dir "$(dirname -- "$base")"
if [[ -e "$base" || -L "$base" ]]; then secure_dir "$base"; fi
atomic_file() {
  local src="$1" dst="$2" mode="$3" temp
  secure_dir "$(dirname -- "$dst")"
  temp=$(mktemp "$(dirname -- "$dst")/.pman-install.XXXXXX")
  if ! install -m "$mode" -- "$src" "$temp" || ! cmp -s -- "$src" "$temp"; then
    rm -f -- "$temp"
    exit 1
  fi
  mv -fT -- "$temp" "$dst"
}
link_package() {
  local target="$1" name="$2"
  [[ "$target" =~ ^releases/[A-Za-z0-9._-]+$ && -d "$base/$target" && ! -L "$base/$target" ]] || {
    echo 'Invalid module release.' >&2
    exit 1
  }
  ln -s -- "$target" "$base/.$name.$$"
  mv -fT -- "$base/.$name.$$" "$base/$name"
}
# Preserve a manually disabled checker on upgrades; enable it on first installation.
TIMER_MASKED=0
if [[ -L "$units/pman-maintenance-sources.timer" && "$(readlink -- "$units/pman-maintenance-sources.timer")" == /dev/null ]]; then
  TIMER_MASKED=1
fi
if [[ "$TIMER" == auto ]]; then
  TIMER=1
  if [[ -z "$DESTDIR" && -f "$units/pman-maintenance-sources.timer" ]]; then
    if ! systemctl is-enabled --quiet pman-maintenance-sources.timer; then TIMER=0; fi
  fi
fi
if [[ "$ACTION" == uninstall ]]; then
  if [[ -z "$DESTDIR" ]]; then
    systemctl disable --now pman-maintenance-sources.timer || true
    systemctl stop pman-maintenance-sources.service || true
  fi
  secure_dir "$(dirname -- "$base")"
  [[ ! -L "$base" ]] || {
    echo 'Unsafe module directory.' >&2
    exit 1
  }
  rm -rf -- "$base"
  rm -f -- "$bin/pman-maintenance" "$units/pman-maintenance-sources.service" "$units/pman-maintenance-sources.timer"
  [[ -n "$DESTDIR" ]] || systemctl daemon-reload
  echo 'Maintenance module removed; pman core, health cron and diagnostic state retained.'
  exit 0
fi
if [[ "$ACTION" == rollback ]]; then
  secure_dir "$base"
  previous=$(readlink -- "$base/previous")
  current=$(readlink -- "$base/current")
  link_package "$previous" current
  link_package "$current" previous
  echo 'Maintenance module rolled back.'
  exit 0
fi
if [[ "$WITH_MAINTENANCE" == auto ]]; then
  WITH_MAINTENANCE=no
  if [[ -t 0 && -t 1 ]]; then
    read -r -p 'Speicher- und Wartungsmodul zusätzlich installieren? [j/N] ' answer
    [[ "$answer" =~ ^[jJyY]$ ]] && WITH_MAINTENANCE=yes
  fi
fi
command -v python3 >/dev/null || {
  echo 'python3 is required (bundled with PVE).' >&2
  exit 1
}
if [[ "$WITH_MAINTENANCE" == yes ]]; then
  python3 -I -B -c 'import curses' || {
    echo 'Python curses support missing; module not installed.' >&2
    exit 1
  }
fi
atomic_file "$SCRIPT_DIR/proxmox-manager.sh" "$bin/pman" 0755
if [[ "$WITH_MAINTENANCE" == yes ]]; then
  version=$(python3 -I -B "$SCRIPT_DIR/maintenance/launcher.py" --version)
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
  secure_dir "$base/releases"
  stage=$(mktemp -d "$base/releases/.stage.XXXXXX")
  trap '[[ -z "${stage:-}" ]] || rm -rf -- "$stage"' EXIT
  install -m 0644 "$SCRIPT_DIR/maintenance/launcher.py" "$SCRIPT_DIR/maintenance/sources.json" "$stage/"
  mkdir "$stage/pman_maintenance"
  for source in "$SCRIPT_DIR"/maintenance/pman_maintenance/*.py; do
    install -m 0644 "$source" "$stage/pman_maintenance/"
  done
  chmod 0755 "$stage" "$stage/pman_maintenance"
  python3 -I -B "$stage/launcher.py" --interface >/dev/null
  # A content digest permits multiple development builds without modifying an installed release.
  digest=$(cd "$stage" && find . -type f \( -name '*.py' -o -name sources.json \) -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-12)
  release="$version-$digest"
  if [[ ! -e "$base/releases/$release" ]]; then
    mv -T -- "$stage" "$base/releases/$release"
  else
    rm -rf -- "$stage"
  fi
  stage=''
  if [[ -L "$base/current" ]]; then
    old=$(readlink -- "$base/current")
    [[ "$old" == "releases/$release" ]] || link_package "$old" previous
  fi
  link_package "releases/$release" current
  atomic_file "$SCRIPT_DIR/maintenance/pman-maintenance" "$bin/pman-maintenance" 0755
  secure_dir "$DESTDIR/var/lib/pman-maintenance"
  chmod 0700 "$DESTDIR/var/lib/pman-maintenance"
  for name in service timer; do
    if [[ "$name" == timer && "$TIMER_MASKED" == 1 ]]; then continue; fi
    atomic_file "$SCRIPT_DIR/maintenance/systemd/pman-maintenance-sources.$name" "$units/pman-maintenance-sources.$name" 0644
  done
  if [[ -z "$DESTDIR" ]]; then
    systemctl daemon-reload
    if ((TIMER_MASKED)); then
      echo 'Source metadata timer remains masked.'
    elif ((TIMER)); then
      systemctl enable --now pman-maintenance-sources.timer
    else
      systemctl disable --now pman-maintenance-sources.timer
    fi
  fi
  echo 'Maintenance module installed. Disable daily metadata checks with systemctl disable --now pman-maintenance-sources.timer.'
fi
echo 'Installed pman. Existing health cron and guest settings were not changed.'
