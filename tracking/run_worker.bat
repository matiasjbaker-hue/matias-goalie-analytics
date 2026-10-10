@echo off
cd /d "%~dp0"
".venv\Scripts\pythonw.exe" -u worker.py >> worker.log 2>&1
