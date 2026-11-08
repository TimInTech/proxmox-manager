#!/usr/bin/env bash
# Isolated regression checks: only mocked qm/pvesh, never a Proxmox host.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import json, os, pathlib, subprocess, tempfile
source = pathlib.Path('proxmox-manager.sh').read_text().rsplit('\nmain "$@"', 1)[0]
fixture = {'type':'spice','host':'PVE_PROXY_TICKET','proxy':'http://pve.example:3128','tls-port':61000,'password':'SECRET_TICKET','ca':'CERT\\nLINE','host-subject':'CN=pve','delete-this-file':1}
with tempfile.TemporaryDirectory() as td:
    env = dict(os.environ, TMPDIR=td, SPICE_FIXTURE=json.dumps(fixture), CALL_LOG=td+'/calls')
    setup = r'''
qm() {
  local IFS=" "
  if [[ "$1" == config ]]; then
    [[ "${CONFIG_FAIL:-0}" == 0 ]] || return 1
    printf '%s\n' "${VGA_CONFIG:-vga: virtio,memory=128,clipboard=vnc}"
  elif [[ "$1" == set ]]; then
    printf '%s\n' "$*" >>"$CALL_LOG"
    [[ "${SET_FAIL:-0}" == 0 ]]
  else return 1; fi
}
pvesh() { local IFS=" "; printf '%s\n' "$*" >>"$CALL_LOG"; [[ "${PROXY_FAIL:-0}" == 0 ]] || return 1; printf '%s\n' "$SPICE_FIXTURE"; }
_local_node() { printf pve; }
confirm() { return 1; }
have() { [[ "$1" != virt-viewer && "$1" != remote-viewer ]]; }
'''
    def run(body, **extra):
        pathlib.Path(env['CALL_LOG']).write_text('')
        p = subprocess.run(['bash','-c',source+'\n'+setup+'\n'+body],env=dict(env,**extra),capture_output=True,text=True)
        return p, pathlib.Path(env['CALL_LOG']).read_text()
    failures=[]
    def check(name, condition):
        print(('PASS ' if condition else 'FAIL ')+name)
        if not condition: failures.append(name)
    p, calls=run('spice_enable 999999')
    check('enable preserves VGA properties without inventing a port', 'set 999999 --vga qxl,memory=128,clipboard=vnc\n' == calls)
    p,calls=run('spice_enable 200',VGA_CONFIG='digest: abc123\nvga: virtio,memory=64')
    check('VGA update protects a supplied config digest',calls=='set 200 --vga qxl,memory=64 --digest abc123\n')
    p,calls=run('spice_enable 200', CONFIG_FAIL='1')
    check('failed config prevents mutation and returns failure',p.returncode!=0 and not calls)
    p,calls=run('spice_enable 200', SET_FAIL='1')
    check('failed VGA update returns failure',p.returncode!=0 and 'enabled' not in p.stdout)
    p,calls=run('spice_enable 200',VGA_CONFIG='vga: qxl2,memory=64')
    check('existing multi-monitor QXL remains unchanged',p.returncode==0 and not calls)
    p,calls=run('spice_info 200 vm-one',PROXMOX_MANAGER_SPICE_ADDR='pve.example')
    files=list(pathlib.Path(td).glob('vm-*.vv'))
    check('connect requests authenticated Proxmox spiceproxy',calls=='create /nodes/pve/qemu/200/spiceproxy --output-format json --proxy pve.example\n')
    check('connection ticket stays out of terminal', 'SECRET_TICKET' not in p.stdout+p.stderr and 'PVE_PROXY_TICKET' not in p.stdout+p.stderr)
    check('private vv carries TLS certificate, proxy and ticket',len(files)==1 and files[0].stat().st_mode & 0o777 == 0o600 and all(s in files[0].read_text() for s in ('tls-port=61000','password=SECRET_TICKET','proxy=http://pve.example:3128','ca=CERT\\nLINE','host-subject=CN=pve')))
    for f in files: f.unlink()
    p,calls=run('spice_info 200 vm-one',PROXY_FAIL='1')
    check('proxy failure leaves no connection file',p.returncode!=0 and not list(pathlib.Path(td).glob('vm-*.vv')))
    p,calls=run('spice_info 200 vm-one',SPICE_FIXTURE='{"type":"spice","password":"SECRET_TICKET"}')
    check('invalid proxy response fails without a ticket leak or file',p.returncode!=0 and 'SECRET_TICKET' not in p.stdout+p.stderr and not list(pathlib.Path(td).glob('vm-*.vv')))
    raise SystemExit(bool(failures))
PY
