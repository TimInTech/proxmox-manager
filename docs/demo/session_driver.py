#!/usr/bin/env python3
"""Deterministic PTY session driver with in-stream pseudonymization for Proxmox Manager demo."""

from __future__ import annotations

import json
import os
import re
import sys
import time
import pexpect


class StreamAnonymizer:
    """Intercepts and pseudonymizes sensitive identifiers in terminal stream."""

    def __init__(
        self,
        target_stream,
        log_path: str | None = None,
        cast_path: str | None = None,
        cols: int = 120,
        rows: int = 34,
    ):
        self.target = target_stream
        self.log_file = open(log_path, "wb") if log_path else None
        self.cast_path = cast_path
        self.cast_file = open(cast_path, "w", encoding="utf-8") if cast_path else None
        self.start_time = time.time()
        if self.cast_file:
            header = {
                "version": 2,
                "width": cols,
                "height": rows,
                "timestamp": int(self.start_time),
                "title": "Proxmox Manager Demo",
                "env": {"TERM": "xterm-256color", "SHELL": "/bin/bash"},
            }
            self.cast_file.write(json.dumps(header) + "\n")
            self.cast_file.flush()
        self.buf = ""

    def write(self, data: bytes | str) -> None:
        text = data.decode("utf-8", errors="replace") if isinstance(data, bytes) else data
        self.buf += text
        self._process(flush_all=False)

    def flush(self) -> None:
        self._process(flush_all=True)
        self.target.flush()
        if self.log_file:
            self.log_file.flush()
        if self.cast_file:
            self.cast_file.flush()

    def close(self) -> None:
        self.flush()
        if self.log_file:
            self.log_file.close()
        if self.cast_file:
            self.cast_file.close()

    def _process(self, flush_all: bool = False) -> None:
        lines = self.buf.split("\n")
        if not flush_all:
            self.buf = lines[-1]
            lines = lines[:-1]
        else:
            self.buf = ""

        for line in lines:
            anon_line = self._anonymize_line(line)
            out_str = anon_line + "\n" if not flush_all or line != lines[-1] or self.buf else anon_line
            out_bytes = out_str.encode("utf-8")
            self.target.write(out_bytes)
            self.target.flush()
            if self.log_file:
                self.log_file.write(out_bytes)
            if self.cast_file:
                rel_time = round(time.time() - self.start_time, 4)
                self.cast_file.write(json.dumps([rel_time, "o", out_str]) + "\n")
                self.cast_file.flush()

    def _anonymize_line(self, line: str) -> str:
        # 1. Title replacement: Replace 'Proxmox VM/CT Manager' (22 chars)
        # with 'PROXMOX MANAGER      ' (22 chars), exactly length-preserving.
        line = line.replace("Proxmox VM/CT Manager", "PROXMOX MANAGER      ")

        # 2. Header Node line: replace 'pve' with 'pve-node-01' and reduce padding spaces
        if "Node:" in line and "PVE:" in line:
            def repl_node(m):
                prefix = m.group(1)
                middle = m.group(2)
                spaces = m.group(3)
                border = m.group(4)
                diff = len("pve-node-01") - len("pve")
                trimmed_spaces = spaces[diff:] if len(spaces) >= diff else spaces
                return f"{prefix}pve-node-01{middle}{trimmed_spaces}{border}"

            line = re.sub(
                r"(\x1b\[1mNode:\x1b\[0m\s*\x1b\[37m)pve(\x1b\[0m.*?)(\s{10,})(\x1b\[94m║)",
                repl_node,
                line,
            )
            if "pve-node-01" not in line:
                line = re.sub(
                    r"(\bNode:\s*)pve(\s*\|\s*PVE:.*?)( {10,})(║)",
                    lambda m: f"{m.group(1)}pve-node-01{m.group(2)}{m.group(3)[8:]}{m.group(4)}",
                    line,
                )

        # 3. IP addresses: replace 192.168.178.xxx or any 192.168.x.x with 192.0.2.xxx (RFC 5737 TEST-NET-1)
        line = re.sub(
            r"\b192\.168\.178\.(\d{1,3})\b",
            lambda m: f"192.0.2.{m.group(1)}".ljust(len(m.group(0))),
            line,
        )
        line = re.sub(
            r"\b192\.168\.(\d{1,3})\.(\d{1,3})\b",
            lambda m: f"192.0.2.{m.group(2)}".ljust(len(m.group(0))),
            line,
        )

        # 4. Hostnames
        line = re.sub(r"\bpve\.fritz\.box\b", "pve-node-01.lan ", line)
        line = re.sub(r"\bfritz\.box\b", "localdomain", line)

        # 5. SSH disconnect banner
        line = re.sub(r"Connection to .* closed\.", "", line)

        return line


def drive_session(log_path: str | None = None, cast_path: str | None = None) -> None:
    ready_marker = "/tmp/pman_demo_ready"
    if os.path.exists(ready_marker):
        os.remove(ready_marker)

    try:
        cols, rows = os.get_terminal_size()
    except Exception:
        cols, rows = 120, 34

    anonymizer = StreamAnonymizer(
        sys.stdout.buffer,
        log_path=log_path,
        cast_path=cast_path,
        cols=cols,
        rows=rows,
    )
    
    # Notify orchestrator that terminal is open and ready
    with open(ready_marker, "w") as f:
        f.write("ready\n")

    # Spawn remote pman interactive session over SSH
    child = pexpect.spawn(
        "ssh",
        [
            "-tt",
            "-q",
            "-o", "LogLevel=ERROR",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8",
            "pve",
            "TERM=xterm-256color",
            "pman",
        ],
        encoding=None,
        echo=False,
        dimensions=(rows, cols),
    )
    child.logfile_read = anonymizer

    try:
        # Phase 1: Wait for Startansicht (main menu table and prompt)
        child.expect(b"\xe2\x86\x92", timeout=12)  # '→'
        # Hold start view for ~2.5s (t=2.0s OCR will capture 'PROXMOX MANAGER')
        time.sleep(2.5)

        # Phase 2: Open Health overview
        child.send(b"h\n")
        child.expect(b"Press Enter to continue...", timeout=10)
        # Hold health view for ~5.0s (t=8.0s OCR will capture 'Health')
        time.sleep(5.0)

        # Phase 3: Return to Main Menu
        child.send(b"\n")
        child.expect(b"\xe2\x86\x92", timeout=10)
        time.sleep(1.5)

        # Phase 4: Open Maintenance Menu
        child.send(b"m\n")
        child.expect(b"Storage, Dateisysteme", timeout=10)
        time.sleep(0.8)

        # Navigate down 3 times to 'Community PVE-Werkzeuge'
        child.send(b"\x1bOB\x1bOB\x1bOB")
        child.expect(b"Community PVE-Werkzeuge", timeout=5)
        time.sleep(0.8)

        # Enter Community PVE tools list
        child.send(b"\n")
        child.expect(b"COMMUNITY PVE-WERKZEUGE", timeout=5)
        # Hold community tools view for ~4.8s (t=18.0s OCR will capture 'Community PVE')
        time.sleep(4.8)

        # Phase 5: Exit Community view back to Maintenance menu
        child.send(b"\x1b")  # ESC
        child.expect(b"Community-Werkzeug", timeout=5)
        time.sleep(0.6)

        # Phase 6: Exit Maintenance back to Main Menu
        child.send(b"q")
        child.expect(b"\xe2\x86\x92", timeout=5)
        time.sleep(0.6)

        # Phase 7: Exit pman cleanly
        child.send(b"q\n")
        child.expect(pexpect.EOF, timeout=5)
    finally:
        anonymizer.flush()
        anonymizer.close()
        child.close(force=True)


def main() -> int:
    log_dir = os.path.join(os.path.dirname(__file__), "out")
    os.makedirs(log_dir, exist_ok=True)
    log_path = os.path.join(log_dir, "pty_stream.log")
    cast_path = os.path.join(log_dir, "proxmox-manager-demo.cast")
    
    # Empty existing log and cast
    open(log_path, "wb").close()
    open(cast_path, "w", encoding="utf-8").close()
    
    drive_session(log_path=log_path, cast_path=cast_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
