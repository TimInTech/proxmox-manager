#compdef pman proxmox-manager.sh
# Zsh completion for pman / proxmox-manager.sh
#
# Installation (one-time):
#   sudo cp completions/pman.zsh /usr/share/zsh/vendor-completions/_pman
# Or for the current user (add to a directory in $fpath, then run compinit):
#   mkdir -p ~/.zsh/completions
#   cp completions/pman.zsh ~/.zsh/completions/_pman
#   echo 'fpath=(~/.zsh/completions $fpath)' >> ~/.zshrc
#   echo 'autoload -Uz compinit && compinit' >> ~/.zshrc

_pman() {
  _arguments -s \
    '(- *)--help[Show help and exit]' \
    '(- *)--version[Print version and exit]' \
    '--list[Print plain-text overview of all VMs/CTs]' \
    '--json[Print machine-readable JSON output]' \
    '--filter[Filter output by status]:status:(running stopped paused)' \
    '--no-clear[Do not clear the screen in interactive mode]' \
    '--once[Run a single interactive refresh cycle]' \
    '--timeout[Timeout in seconds for stop operations]:seconds:(10 30 60 120 300)' \
    '--force[Skip all confirmation prompts]'
}

_pman "$@"
