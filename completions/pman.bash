# Bash completion for pman / proxmox-manager.sh
# Installation (one-time):
#   sudo cp completions/pman.bash /etc/bash_completion.d/pman
# Or for the current user:
#   source completions/pman.bash  (add to ~/.bashrc for persistence)

_pman() {
  local cur prev words cword
  _init_completion 2>/dev/null || {
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
  }

  local all_flags="--list --json --filter --no-clear --once --timeout --force --version --help"

  case "$prev" in
    --filter)
      COMPREPLY=($(compgen -W "running stopped paused" -- "$cur"))
      return 0
      ;;
    --timeout)
      # Suggest common timeout values; user can type any positive integer
      COMPREPLY=($(compgen -W "10 30 60 120 300" -- "$cur"))
      return 0
      ;;
  esac

  COMPREPLY=($(compgen -W "$all_flags" -- "$cur"))
  return 0
}

complete -F _pman pman
complete -F _pman proxmox-manager.sh
