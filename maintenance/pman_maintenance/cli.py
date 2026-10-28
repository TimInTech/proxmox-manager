"""CLI and noninteractive diagnostics for the optional module."""
import argparse
import json
import os
import sys
from . import INTERFACE, VERSION
from .actions import Context, action_for, execute
from .runner import Runner
from .sources import check_sources, source_report


def main(argv=None):
    parser = argparse.ArgumentParser(description='Optionales pman Speicher- und Wartungsmodul')
    parser.add_argument('--interface', action='store_true', help='Maschinenlesbare Schnittstellenversion')
    parser.add_argument('--version', action='version', version=VERSION)
    parser.add_argument('--scope', choices=('host', 'ct', 'vm'), default='host')
    parser.add_argument('--id', type=int)
    parser.add_argument('--scan-path', choices=('/var', '/home', '/opt', '/srv'), default='/var')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--check-sources', action='store_true', help='Öffentliche Quellmetadaten prüfen')
    mode.add_argument('--sources', action='store_true', help='Herkunft und gespeicherten Status anzeigen')
    mode.add_argument('--report', metavar='ACTION', help='Nur lesende Aktion ohne TUI ausführen')
    parser.add_argument('--json', action='store_true', help='Diagnose als JSON ausgeben')
    args = parser.parse_args(argv)
    if args.interface:
        print(json.dumps({'interface': INTERFACE, 'version': VERSION}))
        return 0
    if os.geteuid() != 0:
        parser.error('Als root auf dem Proxmox-Host ausführen.')
    try:
        ctx = Context(args.scope, args.id, args.scan_path)
        if args.check_sources:
            value = check_sources()
            print(json.dumps(value, ensure_ascii=False, indent=2))
            return 1 if any(r['status'] in ('Quelle fehlt', 'Prüfung fehlgeschlagen') for r in value['references']) else 0
        if args.sources:
            text = source_report()
        elif args.report:
            if action_for(args.report, ctx).mutation:
                parser.error('Änderungen sind nur in der TUI mit Bestätigung möglich.')
            text = execute(args.report, ctx, Runner())
        else:
            if args.json:
                parser.error('--json benötigt --report oder --sources.')
            if not sys.stdin.isatty() or not sys.stdout.isatty():
                parser.error('TUI benötigt ein Terminal; --report für lesende CLI-Ausgaben verwenden.')
            from .ui import run_tui
            run_tui(ctx)
            return 0
        if args.json:
            print(json.dumps({'scope': ctx.scope, 'id': ctx.id, 'report': text}, ensure_ascii=False))
        else:
            from .ui import clean_text
            print(clean_text(text))
        return 0
    except (OSError, RuntimeError, ValueError) as exc:
        from .ui import clean_text
        print('Fehler: {}'.format(clean_text(exc)), file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print('Abgebrochen.', file=sys.stderr)
        return 130
