# Phase 6 - Validation

## bash -n
```
$ find . -name '*.sh' -print
./proxmox-manager.sh
./tests/run.sh
./install_dependencies.sh
```

```
$ bash -n <each .sh>

(exitcode=0)
```

## shellcheck
```
$ shellcheck -S style -f gcc <all .sh>

(exitcode=0)
```

## tests/run.sh
```
$ tests/run.sh
tests/run.sh OK
(exitcode=0)
```
