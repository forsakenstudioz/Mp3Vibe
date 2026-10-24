@echo off
rem Double-click to start syncing. Put a shortcut to this file in shell:startup
rem to start it automatically when Windows starts.
cd /d "%~dp0"
if not exist .venv (
  echo First run: setting things up, this takes a few minutes...
  py -3 -m venv .venv || python -m venv .venv
  .venv\Scripts\python -m pip install --upgrade pip
  .venv\Scripts\python -m pip install -r requirements.txt
)
.venv\Scripts\python vibe_sync.py
pause
