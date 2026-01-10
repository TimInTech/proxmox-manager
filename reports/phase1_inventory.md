# Phase 1 - Repository Inventory

## Structure (max depth 4)
```
.
├── CODE_OF_CONDUCT.md
├── CONTRIBUTING.md
├── docs
│   └── screenshots
│       └── Screenshot.png
├── .editorconfig
├── .git
│   ├── COMMIT_EDITMSG
│   ├── config
│   ├── description
│   ├── FETCH_HEAD
│   ├── HEAD
│   ├── hooks
│   │   ├── applypatch-msg.sample
│   │   ├── commit-msg.sample
│   │   ├── fsmonitor-watchman.sample
│   │   ├── post-update.sample
│   │   ├── pre-applypatch.sample
│   │   ├── pre-commit.sample
│   │   ├── pre-merge-commit.sample
│   │   ├── prepare-commit-msg.sample
│   │   ├── pre-push.sample
│   │   ├── pre-rebase.sample
│   │   ├── pre-receive.sample
│   │   ├── push-to-checkout.sample
│   │   ├── sendemail-validate.sample
│   │   └── update.sample
│   ├── index
│   ├── info
│   │   └── exclude
│   ├── logs
│   │   ├── HEAD
│   │   └── refs
│   │       ├── heads
│   │       └── remotes
│   ├── objects
│   │   ├── 61
│   │   │   └── 32c8a9a156454085278c9ca4bbce747c36c0f2
│   │   ├── 6a
│   │   │   └── 6f3e20e1c901d06c65a340098071a6f32042d9
│   │   ├── 83
│   │   │   └── a99319b2539ca93a17ba0b157f1f11c9344673
│   │   ├── a6
│   │   │   └── a1d2db5811078d305d4cd9bef740b351e8eb31
│   │   ├── ad
│   │   │   └── 83ac6219bb9cf0a7a6bc7d8cfba3047840117d
│   │   ├── e6
│   │   │   └── 2871f61b921ba799040ce6146abe8a2bdbd39c
│   │   ├── info
│   │   └── pack
│   │       ├── pack-6c69a273d4d82ef4f7c7070f7fc9249582f79cfa.idx
│   │       ├── pack-6c69a273d4d82ef4f7c7070f7fc9249582f79cfa.pack
│   │       └── pack-6c69a273d4d82ef4f7c7070f7fc9249582f79cfa.rev
│   ├── ORIG_HEAD
│   ├── packed-refs
│   └── refs
│       ├── heads
│       │   ├── audit
│       │   ├── main
│       │   └── test
│       ├── remotes
│       │   └── origin
│       └── tags
├── .gitattributes
├── .gitignore
├── .gitleaks.baseline
├── install_dependencies.sh
├── LICENSE
├── .markdownlint.yaml
├── proxmox-manager.sh
├── README.md
├── REPORT_PROXMOX_RESTORE.md
├── reports
│   └── phase1_inventory.md
├── SECURITY.md
└── tests

28 directories, 49 files
```

## Key Files
- Entrypoint: proxmox-manager.sh
- Installer: install_dependencies.sh
- Docs: README.md, SECURITY.md, CODE_OF_CONDUCT.md, CONTRIBUTING.md
- Reports: REPORT_PROXMOX_RESTORE.md, reports/

## Tech Stack
- Bash script (single-file tool) with Proxmox CLI `qm` and `pct` integration
- Optional tools: `jq`, `virt-viewer`, `shellcheck` via install script

## Entry Points / Critical Paths
- CLI: `--list`, `--json`, interactive TUI default
- Actions: snapshots, SPICE enable/info, console entry
