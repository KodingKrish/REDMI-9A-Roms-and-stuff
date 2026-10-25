@echo off
:: Navigate to the folder where this batch script is saved
cd /d "%~dp0"

echo ==========================================
echo   Git Auto-Push Automation Script
echo ==========================================

:: 1. Check current status
echo Checking repository status...
git status -s
echo ------------------------------------------

:: 2. Stage all changed files
echo Staging changes...
git add .

:: 3. Generate a clean timestamp for the commit message
for /f "tokens=2 delims==" %%I in ('wmic os get localdatetime /value') do set datetime=%%I
set TIMESTAMP=%datetime:~0,4%-%datetime:~4,2%-%datetime:~6,2% %datetime:~8,2%:%datetime:~10,2%
set COMMIT_MSG=Auto-update: %TIMESTAMP%

:: 4. Commit locally
echo Committing changes...
git commit -m "%COMMIT_MSG%"

:: 5. Push to GitHub
echo Uploading to GitHub...
git push origin main

echo ==========================================
echo   Execution completed successfully!
echo ==========================================
pause
