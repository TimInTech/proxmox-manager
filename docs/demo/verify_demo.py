#!/usr/bin/env python3
"""Automated verification script for Proxmox Manager demo pipeline.

Validates:
1. Stream geometry, duration, framerate, and size via ffprobe.
2. OCR keyword extraction at seconds 2, 8, and 18 via tesseract.
3. Privacy validation (zero real IPs, zero real node names) across OCR & PTY stream.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys


def run_cmd(cmd: list[str]) -> str:
    res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if res.returncode != 0:
        raise RuntimeError(f"Command failed ({res.returncode}): {' '.join(cmd)}\n{res.stderr}")
    return res.stdout.strip()


def probe_file(path: str) -> dict:
    cmd = [
        "ffprobe",
        "-v", "error",
        "-show_format",
        "-show_streams",
        "-print_format", "json",
        path,
    ]
    raw = run_cmd(cmd)
    return json.loads(raw)


def extract_frame(video_path: str, timestamp_s: float, out_path: str) -> None:
    cmd = [
        "ffmpeg",
        "-y",
        "-ss", str(timestamp_s),
        "-i", video_path,
        "-vframes", "1",
        out_path,
    ]
    run_cmd(cmd)


def ocr_image(img_path: str) -> str:
    cmd = ["tesseract", img_path, "stdout", "-l", "eng+deu", "--psm", "6"]
    return run_cmd(cmd)


def main() -> int:
    base_dir = os.path.dirname(os.path.abspath(__file__))
    out_dir = os.path.join(base_dir, "out")
    raw_video = os.path.join(out_dir, "proxmox-manager-demo-raw.mp4")
    gif_file = os.path.join(out_dir, "proxmox-manager-demo.gif")
    pty_log = os.path.join(out_dir, "pty_stream.log")

    print("=================================================================")
    print("PROXMOX MANAGER DEMO — AUTOMATED EVIDENCE VERIFICATION")
    print("=================================================================\n")

    errors: list[str] = []
    checks: list[tuple[str, str, bool]] = []

    # -------------------------------------------------------------------------
    # 1. STREAM VALIDATION (ffprobe)
    # -------------------------------------------------------------------------
    if not os.path.isfile(raw_video):
        print(f"[FAIL] Raw video missing: {raw_video}")
        return 1
    if not os.path.isfile(gif_file):
        print(f"[FAIL] GIF file missing: {gif_file}")
        return 1

    # Probe Raw Video
    raw_meta = probe_file(raw_video)
    v_stream = next(s for s in raw_meta["streams"] if s["codec_type"] == "video")
    v_width = int(v_stream["width"])
    v_height = int(v_stream["height"])
    v_duration = float(raw_meta["format"]["duration"])
    v_fps_parts = [int(p) for p in v_stream["r_frame_rate"].split("/")]
    v_fps = v_fps_parts[0] / v_fps_parts[1] if len(v_fps_parts) == 2 else float(v_fps_parts[0])

    # Check Raw constraints: 1280x720, 30fps, 20-28s duration
    ok_res = (v_width == 1280 and v_height == 720)
    checks.append(("Raw Video Resolution", f"{v_width}x{v_height} (expected 1280x720)", ok_res))
    if not ok_res:
        errors.append(f"Raw resolution mismatch: {v_width}x{v_height}")

    ok_fps = (29.0 <= v_fps <= 31.0)
    checks.append(("Raw Video Framerate", f"{v_fps:.1f} fps (expected 30 fps)", ok_fps))
    if not ok_fps:
        errors.append(f"Raw framerate mismatch: {v_fps}")

    ok_dur = (20.0 <= v_duration <= 28.0)
    checks.append(("Raw Video Duration", f"{v_duration:.2f}s (expected 20.0s - 28.0s)", ok_dur))
    if not ok_dur:
        errors.append(f"Raw duration out of bounds: {v_duration:.2f}s")

    # Probe GIF
    gif_meta = probe_file(gif_file)
    g_stream = next(s for s in gif_meta["streams"] if s["codec_type"] == "video")
    g_width = int(g_stream["width"])
    g_height = int(g_stream["height"])
    g_size_mb = os.path.getsize(gif_file) / (1024 * 1024)
    g_fps_parts = [int(p) for p in g_stream["r_frame_rate"].split("/")]
    g_fps = g_fps_parts[0] / g_fps_parts[1] if len(g_fps_parts) == 2 else float(g_fps_parts[0])

    ok_g_w = (1100 <= g_width <= 1280)
    checks.append(("GIF Width", f"{g_width} px (expected 1100 - 1280 px)", ok_g_w))
    if not ok_g_w:
        errors.append(f"GIF width out of bounds: {g_width}")

    ok_g_fps = (10.0 <= g_fps <= 12.5)
    checks.append(("GIF Framerate", f"{g_fps:.1f} fps (expected 10 - 12 fps)", ok_g_fps))
    if not ok_g_fps:
        errors.append(f"GIF framerate out of bounds: {g_fps}")

    ok_g_size = (g_size_mb < 10.0)
    checks.append(("GIF File Size", f"{g_size_mb:.2f} MB (target < 10 MB)", ok_g_size))
    if not ok_g_size:
        errors.append(f"GIF size exceeds limit: {g_size_mb:.2f} MB")

    # -------------------------------------------------------------------------
    # 2. FRAME EXTRACTION & OCR (tesseract)
    # -------------------------------------------------------------------------
    import tempfile
    with tempfile.TemporaryDirectory() as tmp_dir:
        f2_path = os.path.join(tmp_dir, "frame_sec02.png")
        f8_path = os.path.join(tmp_dir, "frame_sec08.png")
        f18_path = os.path.join(tmp_dir, "frame_sec18.png")

        extract_frame(raw_video, 2.0, f2_path)
        extract_frame(raw_video, 8.0, f8_path)
        extract_frame(raw_video, 18.0, f18_path)

        ocr_2 = ocr_image(f2_path)
        ocr_8 = ocr_image(f8_path)
        ocr_18 = ocr_image(f18_path)

    # Check keyword 1: "PROXMOX MANAGER" at second 2
    ok_ocr2 = bool(re.search(r"PROXMOX\s+MANAGER", ocr_2, re.IGNORECASE))
    checks.append(("OCR @ 2.0s: 'PROXMOX MANAGER'", "Found in frame" if ok_ocr2 else "MISSING", ok_ocr2))
    if not ok_ocr2:
        errors.append("Keyword 'PROXMOX MANAGER' missing in frame at 2.0s")

    # Check keyword 2: "Health" at second 8
    ok_ocr8 = bool(re.search(r"\bHEALTH\b", ocr_8, re.IGNORECASE))
    checks.append(("OCR @ 8.0s: 'Health'", "Found in frame" if ok_ocr8 else "MISSING", ok_ocr8))
    if not ok_ocr8:
        errors.append("Keyword 'Health' missing in frame at 8.0s")

    # Check keyword 3: "Community PVE" at second 18
    ok_ocr18 = bool(re.search(r"Community\s+PVE", ocr_18, re.IGNORECASE))
    checks.append(("OCR @ 18.0s: 'Community PVE'", "Found in frame" if ok_ocr18 else "MISSING", ok_ocr18))
    if not ok_ocr18:
        errors.append("Keyword 'Community PVE' missing in frame at 18.0s")

    # -------------------------------------------------------------------------
    # 3. PRIVACY CHECK (Regex Scan across OCR, PTY Stream, and Cast)
    # -------------------------------------------------------------------------
    ocr_combined = f"{ocr_2}\n{ocr_8}\n{ocr_18}"
    pty_text = ""
    if os.path.isfile(pty_log):
        with open(pty_log, "rb") as f:
            pty_text = f.read().decode("utf-8", errors="replace")

    cast_file = os.path.join(out_dir, "proxmox-manager-demo.cast")
    cast_text = ""
    if os.path.isfile(cast_file):
        with open(cast_file, "r", encoding="utf-8", errors="replace") as f:
            cast_text = f.read()

    sensitive_patterns = [
        (r"\b192\.168\.\d{1,3}\.\d{1,3}\b", "RFC1918 Private IP (192.168.*)"),
        (r"\b10\.\d{1,3}\.\d{1,3}\.\d{1,3}\b", "RFC1918 Private IP (10.*)"),
        (r"\b172\.(1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}\b", "RFC1918 Private IP (172.16-31.*)"),
        (r"\bNode:\s*pve(?!\w|-)", "Real node identifier ('Node: pve')"),
        (r"\bpve\.fritz\.box\b", "Real FQDN ('pve.fritz.box')"),
        (r"\bfritz\.box\b", "Local FritzBox domain"),
    ]

    privacy_violations: list[str] = []
    for pattern, label in sensitive_patterns:
        m_ocr = re.findall(pattern, ocr_combined, re.IGNORECASE)
        m_pty = re.findall(pattern, pty_text, re.IGNORECASE)
        m_cast = re.findall(pattern, cast_text, re.IGNORECASE)
        if m_ocr:
            privacy_violations.append(f"OCR leak: {label} -> {m_ocr}")
        if m_pty:
            privacy_violations.append(f"PTY leak: {label} -> {m_pty}")
        if m_cast:
            privacy_violations.append(f"Cast leak: {label} -> {m_cast}")

    ok_priv = (len(privacy_violations) == 0)
    checks.append((
        "Privacy Scan (OCR + PTY stream)",
        "0 sensitive patterns detected" if ok_priv else f"{len(privacy_violations)} violations",
        ok_priv,
    ))
    if not ok_priv:
        for v in privacy_violations:
            errors.append(f"Privacy violation: {v}")

    # -------------------------------------------------------------------------
    # REPORT
    # -------------------------------------------------------------------------
    print(f"{'CHECK':<36} | {'MEASURED VALUE':<35} | {'STATUS'}")
    print("-" * 82)
    for name, val, passed in checks:
        status_str = "\033[92m[PASS]\033[0m" if passed else "\033[91m[FAIL]\033[0m"
        print(f"{name:<36} | {val:<35} | {status_str}")
    print("-" * 82)

    if errors:
        print("\n\033[91mVALIDATION FAILED WITH ERRORS:\033[0m")
        for err in errors:
            print(f" - {err}")
        return 1

    print("\n\033[92mALL CRITERIA OBJECTIVELY VALIDATED AND VERIFIED (0 FAILURES).\033[0m\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
