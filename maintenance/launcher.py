#!/usr/bin/python3
"""Installed with an isolated interpreter; load only the adjacent package."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from pman_maintenance.cli import main
raise SystemExit(main())
