#!/usr/bin/env bash
# Start syncing on macOS or Linux: ./start_sync.sh
set -e
cd "$(dirname "$0")"
if [ ! -d .venv ]; then
  echo "First run: setting things up, this takes a few minutes..."
  python3 -m venv .venv
  .venv/bin/pip install --upgrade pip
  .venv/bin/pip install -r requirements.txt
fi
exec .venv/bin/python vibe_sync.py "$@"
