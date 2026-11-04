#!/usr/bin/env python3
"""Builds standalone interactive HTML Web Vector Player for Proxmox Manager demo."""

from __future__ import annotations

import json
import os
import sys

DEMO_DIR = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(DEMO_DIR, "out")
CAST_FILE = os.path.join(OUT_DIR, "proxmox-manager-demo.cast")
HTML_FILE = os.path.join(DEMO_DIR, "index.html")


def build_player() -> None:
    if not os.path.isfile(CAST_FILE):
        print(f"[FAIL] Cast file missing: {CAST_FILE}")
        sys.exit(1)

    with open(CAST_FILE, "r", encoding="utf-8") as f:
        cast_content = f.read()

    # Escape cast content for embedding in JS string safely
    escaped_cast = json.dumps(cast_content)

    html = f"""<!DOCTYPE html>
<html lang="de">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Proxmox Manager — Interaktive Terminal-Demo</title>
  <link rel="stylesheet" href="vendor/asciinema-player.css">
  <style>
    :root {{
      --bg: #0d1117;
      --card-bg: #161b22;
      --border: #30363d;
      --text: #e6edf3;
      --text-muted: #8b949e;
      --accent: #58a6ff;
      --accent-hover: #79c0ff;
      --green: #3fb950;
      --purple: #bc8cff;
    }}

    * {{
      box-sizing: border-box;
      margin: 0;
      padding: 0;
    }}

    body {{
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
      background-color: var(--bg);
      color: var(--text);
      line-height: 1.5;
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      align-items: center;
      padding: 24px 16px;
    }}

    .container {{
      width: 100%;
      max-width: 1024px;
      display: flex;
      flex-direction: column;
      gap: 16px;
    }}

    header {{
      display: flex;
      flex-direction: column;
      gap: 8px;
    }}

    .header-top {{
      display: flex;
      justify-content: space-between;
      align-items: center;
      flex-wrap: wrap;
      gap: 12px;
    }}

    h1 {{
      font-size: 1.5rem;
      font-weight: 600;
      display: flex;
      align-items: center;
      gap: 10px;
    }}

    .badge {{
      display: inline-block;
      font-size: 0.75rem;
      font-weight: 600;
      padding: 3px 8px;
      border-radius: 12px;
      background: rgba(88, 166, 255, 0.15);
      color: var(--accent);
      border: 1px solid rgba(88, 166, 255, 0.3);
    }}

    .badge-success {{
      background: rgba(63, 185, 80, 0.15);
      color: var(--green);
      border-color: rgba(63, 185, 80, 0.3);
    }}

    .subtitle {{
      color: var(--text-muted);
      font-size: 0.95rem;
    }}

    .player-card {{
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 8px;
      overflow: hidden;
      box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4);
    }}

    .window-header {{
      background: #0b0e14;
      border-bottom: 1px solid var(--border);
      padding: 10px 14px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      user-select: none;
    }}

    .dots {{
      display: flex;
      gap: 6px;
    }}

    .dot {{
      width: 11px;
      height: 11px;
      border-radius: 50%;
    }}

    .dot-red {{ background: #ff5f56; }}
    .dot-yellow {{ background: #ffbd2e; }}
    .dot-green {{ background: #27c93f; }}

    .window-title {{
      font-family: monospace;
      font-size: 0.82rem;
      color: var(--text-muted);
    }}

    #player {{
      width: 100%;
      min-height: 480px;
    }}

    .asciinema-player-theme-monokai {{
      --term-font-family: "DejaVu Sans Mono", "Fira Code", monospace;
    }}

    .chapters {{
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      padding: 12px 14px;
      background: #0e1217;
      border-top: 1px solid var(--border);
      align-items: center;
    }}

    .chapters-label {{
      font-size: 0.82rem;
      font-weight: 600;
      color: var(--text-muted);
      margin-right: 4px;
    }}

    .chapter-btn {{
      background: #21262d;
      border: 1px solid var(--border);
      color: var(--text);
      font-size: 0.8rem;
      padding: 5px 10px;
      border-radius: 6px;
      cursor: pointer;
      transition: all 0.15s ease;
      display: inline-flex;
      align-items: center;
      gap: 6px;
    }}

    .chapter-btn:hover {{
      background: #30363d;
      border-color: var(--accent);
      color: var(--accent-hover);
    }}

    .chapter-time {{
      color: var(--accent);
      font-family: monospace;
      font-size: 0.75rem;
    }}

    .info-grid {{
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
      gap: 12px;
      margin-top: 4px;
    }}

    .info-card {{
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 6px;
      padding: 14px;
    }}

    .info-card h3 {{
      font-size: 0.9rem;
      font-weight: 600;
      margin-bottom: 6px;
      color: var(--accent);
    }}

    .info-card p, .info-card ul {{
      font-size: 0.82rem;
      color: var(--text-muted);
    }}

    .info-card ul {{
      padding-left: 18px;
      margin-top: 4px;
    }}

    .info-card li {{
      margin-bottom: 3px;
    }}

    kbd {{
      background: #21262d;
      border: 1px solid var(--border);
      border-radius: 3px;
      box-shadow: 0 1px 0 rgba(0,0,0,0.2);
      color: var(--text);
      display: inline-block;
      font-family: monospace;
      font-size: 0.75rem;
      padding: 1px 5px;
    }}

    footer {{
      margin-top: auto;
      padding: 16px 0;
      font-size: 0.8rem;
      color: var(--text-muted);
      text-align: center;
    }}

    footer a {{
      color: var(--accent);
      text-decoration: none;
    }}

    footer a:hover {{
      text-decoration: underline;
    }}
  </style>
</head>
<body>
  <div class="container">
    <header>
      <div class="header-top">
        <h1>
          <span>Proxmox Manager</span>
          <span class="badge">v2.14.0</span>
          <span class="badge badge-success">Vektor-Demo</span>
        </h1>
        <div style="font-size: 0.85rem;">
          <a href="https://github.com/TimInTech/proxmox-manager" target="_blank" style="color: var(--accent); text-decoration: none;">GitHub Repository &rarr;</a>
        </div>
      </div>
      <p class="subtitle">Interaktive, verlustfreie Terminal-Aufzeichnung mit pausierbarem Ablauf, Zeitstrahl und frei markierbarem Text.</p>
    </header>

    <div class="player-card">
      <div class="window-header">
        <div class="dots">
          <div class="dot dot-red"></div>
          <div class="dot dot-yellow"></div>
          <div class="dot dot-green"></div>
        </div>
        <div class="window-title">pve-node-01: pman &mdash; 120&times;34</div>
        <div style="width: 40px;"></div>
      </div>

      <div id="player"></div>

      <div class="chapters">
        <span class="chapters-label">Kapitel:</span>
        <button class="chapter-btn" onclick="seekTo(0)">
          <span class="chapter-time">0:00</span> Startansicht
        </button>
        <button class="chapter-btn" onclick="seekTo(5.8)">
          <span class="chapter-time">0:05</span> Health Check (h)
        </button>
        <button class="chapter-btn" onclick="seekTo(11.8)">
          <span class="chapter-time">0:11</span> Hauptmenü
        </button>
        <button class="chapter-btn" onclick="seekTo(15.7)">
          <span class="chapter-time">0:15</span> Wartungsmenü (m)
        </button>
        <button class="chapter-btn" onclick="seekTo(17.4)">
          <span class="chapter-time">0:17</span> Helper-Scripts (Community)
        </button>
        <button class="chapter-btn" onclick="seekTo(26.7)">
          <span class="chapter-time">0:26</span> Bestätigung vor dem Start
        </button>
        <button class="chapter-btn" onclick="seekTo(32.3)">
          <span class="chapter-time">0:32</span> Quellcode ansehen (v)
        </button>
        <button class="chapter-btn" onclick="seekTo(39.4)">
          <span class="chapter-time">0:39</span> Beenden (q)
        </button>
      </div>
    </div>

    <div class="info-grid">
      <div class="info-card">
        <h3>Interaktion & Steuerung</h3>
        <ul>
          <li><kbd>Leertaste</kbd> oder Klick ins Terminal: Play / Pause</li>
          <li><kbd>&larr;</kbd> / <kbd>&rarr;</kbd>: 5 Sekunden vor / zurückspringen</li>
          <li><kbd>f</kbd>: Vollbildmodus umschalten</li>
          <li><strong>Text-Auswahl:</strong> Jeder Text im Terminal kann mit der Maus markiert und per <kbd>Strg+C</kbd> kopiert werden.</li>
        </ul>
      </div>

      <div class="info-card">
        <h3>Datenschutz & Sicherheit</h3>
        <ul>
          <li><strong>In-Stream-Pseudonymisierung:</strong> Reale IPs werden im Bytestrom durch RFC 5737 TEST-NET-1 (192.0.2.*) ersetzt.</li>
          <li><strong>Keine Verschiebungen:</strong> Box-Drawing-Zeichen (&boxv;, &boxh;, &boxdr;) bleiben bytegenau ausgerichtet.</li>
          <li><strong>100% Read-Only:</strong> Keine Reboots, Bestätigungen oder schreibenden Aktionen.</li>
        </ul>
      </div>

      <div class="info-card">
        <h3>Rendering-Architektur</h3>
        <ul>
          <li><strong>Vektor-Engine:</strong> Native ANSI/VT100-Wiedergabe über WebAssembly/Canvas (Asciinema v3).</li>
          <li><strong>Keine Kantenunschärfe:</strong> Gestochen scharfe Monospace-Schrift bei jeder Zoomstufe.</li>
          <li><strong>Geringe Dateigröße:</strong> Gesamter Session-Cast umfasst nur ~33 KB (vs. 870 KB GIF).</li>
        </ul>
      </div>
    </div>

    <footer>
      Proxmox Manager &bull; Open Source unter MIT Lizenz &bull; <a href="https://github.com/TimInTech/proxmox-manager">GitHub</a>
    </footer>
  </div>

  <script src="vendor/asciinema-player.min.js"></script>
  <script>
    let playerInstance = null;
    const embeddedCast = {escaped_cast};

    function initPlayer() {{
      const container = document.getElementById('player');
      
      // Determine source: fetch if HTTP/HTTPS, fallback to embedded data string if file:// or fetch fails
      const isHttp = window.location.protocol.startsWith('http');
      const src = isHttp ? 'out/proxmox-manager-demo.cast' : {{ data: embeddedCast }};

      try {{
        playerInstance = AsciinemaPlayer.create(src, container, {{
          autoPlay: true,
          loop: true,
          speed: 1.0,
          theme: 'monokai',
          fit: 'width',
          terminalFontFamily: '"DejaVu Sans Mono", "Cascadia Code", "Fira Code", monospace'
        }});
      }} catch (err) {{
        console.warn('Initial load failed, falling back to embedded cast string:', err);
        playerInstance = AsciinemaPlayer.create({{ data: embeddedCast }}, container, {{
          autoPlay: true,
          loop: true,
          speed: 1.0,
          theme: 'monokai',
          fit: 'width',
          terminalFontFamily: '"DejaVu Sans Mono", "Cascadia Code", "Fira Code", monospace'
        }});
      }}
    }}

    function seekTo(seconds) {{
      if (playerInstance && typeof playerInstance.seek === 'function') {{
        playerInstance.seek(seconds);
      }}
    }}

    document.addEventListener('DOMContentLoaded', initPlayer);
  </script>
</body>
</html>
"""

    with open(HTML_FILE, "w", encoding="utf-8") as f:
        f.write(html)

    print(f"[OK] Generated interactive Web Vector Player: {HTML_FILE}")


if __name__ == "__main__":
    build_player()
