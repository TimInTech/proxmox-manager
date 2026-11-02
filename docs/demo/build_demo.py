#!/usr/bin/env python3
"""Deterministic Headless Pipeline to build pixel-perfect GIF & raw MP4 demo for Proxmox Manager."""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import time

DEMO_DIR = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(DEMO_DIR, "out")
RAW_VIDEO = os.path.join(OUT_DIR, "proxmox-manager-demo-raw.mp4")
GIF_FILE = os.path.join(OUT_DIR, "proxmox-manager-demo.gif")
SESSION_DRIVER = os.path.join(DEMO_DIR, "session_driver.py")
VERIFY_SCRIPT = os.path.join(DEMO_DIR, "verify_demo.py")
BUILD_PLAYER = os.path.join(DEMO_DIR, "build_player.py")
DISPLAY_NUM = ":99"


def main() -> int:
    os.makedirs(OUT_DIR, exist_ok=True)
    print("=================================================================")
    print("PROXMOX MANAGER DEMO — DETERMINISTIC HEADLESS PIPELINE")
    print("=================================================================")
    print(f"Target Video: {RAW_VIDEO}")
    print(f"Target GIF:   {GIF_FILE}")
    print("Display:      Xvfb 1280x720x24 on " + DISPLAY_NUM)

    # 1. Clean up stale Xvfb and marker
    subprocess.run(["pkill", "-f", f"Xvfb {DISPLAY_NUM}"], stderr=subprocess.DEVNULL)
    ready_marker = "/tmp/pman_demo_ready"
    if os.path.exists(ready_marker):
        os.remove(ready_marker)
    time.sleep(0.5)

    # 2. Launch Xvfb
    print("\n[1/5] Launching isolated Xvfb server...")
    xvfb_proc = subprocess.Popen(
        ["Xvfb", DISPLAY_NUM, "-screen", "0", "1280x720x24"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    time.sleep(1.2)
    if xvfb_proc.poll() is not None:
        print("[FAIL] Failed to start Xvfb.")
        return 1

    # 3. Launch Kitty with deterministic session driver
    print("[2/5] Initializing Kitty terminal and PTY state machine...")
    kitty_cmd = [
        "kitty",
        "--override", "linux_display_server=x11",
        "--override", "hide_window_decorations=yes",
        "--override", "remember_window_size=no",
        "--override", "initial_window_width=1280",
        "--override", "initial_window_height=720",
        "--override", "window_padding_width=24",
        "--override", "font_family=DejaVu Sans Mono",
        "--override", "font_size=15.5",
        "--override", "cursor_shape=block",
        "--override", "cursor_blink_interval=0",
        "--override", "background=#0d1117",
        "--override", "foreground=#e6edf3",
        "python3", SESSION_DRIVER,
    ]

    kitty_env = os.environ.copy()
    kitty_env["DISPLAY"] = DISPLAY_NUM
    kitty_env["LIBGL_ALWAYS_SOFTWARE"] = "1"

    kitty_proc = subprocess.Popen(kitty_cmd, env=kitty_env, stderr=subprocess.DEVNULL)

    # Wait for session driver to signal ready
    print("      Waiting for terminal mapping and session driver ready signal...")
    t_start = time.time()
    while not os.path.exists(ready_marker) and time.time() - t_start < 10.0:
        time.sleep(0.05)

    # 4. Start ffmpeg x11grab exactly synchronized with live session
    print("[3/5] Starting lossless 30 fps x11grab recorder...")
    ffmpeg_cmd = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel", "error",
        "-y",
        "-f", "x11grab",
        "-draw_mouse", "0",
        "-framerate", "30",
        "-video_size", "1280x720",
        "-i", f"{DISPLAY_NUM}.0",
        "-c:v", "libx264",
        "-preset", "fast",
        "-crf", "18",
        "-pix_fmt", "yuv420p",
        RAW_VIDEO,
    ]
    rec_proc = subprocess.Popen(ffmpeg_cmd)

    # Wait for Kitty to complete
    kitty_code = kitty_proc.wait()
    print(f"      Session driver finished with exit code: {kitty_code}")

    # Allow ffmpeg to capture the final state
    time.sleep(0.3)

    # Stop ffmpeg gracefully
    print("[4/5] Finalizing raw MP4 recording...")
    rec_proc.send_signal(signal.SIGINT)
    try:
        rec_proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        rec_proc.terminate()
        rec_proc.wait()

    # Terminate Xvfb
    xvfb_proc.terminate()
    xvfb_proc.wait()

    # 5. Export pixel-perfect GIF
    print("[5/5] Generating optimized sharp GIF (stats_mode=diff, dither=none)...")
    gif_cmd = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel", "error",
        "-y",
        "-i", RAW_VIDEO,
        "-filter_complex",
        "[0:v]fps=12,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=none",
        "-loop", "0",
        GIF_FILE,
    ]
    subprocess.run(gif_cmd, check=True)

    # 6. Build interactive Web Vector Player
    print("\n[6/6] Generating interactive Web Vector Player (index.html)...")
    subprocess.run([sys.executable, BUILD_PLAYER], check=True)

    print("\n-----------------------------------------------------------------")
    print("PIPELINE COMPLETED. RUNNING AUTOMATED VERIFICATION SUITE...")
    print("-----------------------------------------------------------------\n")
    
    # Run verification suite
    verify_proc = subprocess.run([sys.executable, VERIFY_SCRIPT])
    return verify_proc.returncode


if __name__ == "__main__":
    sys.exit(main())
