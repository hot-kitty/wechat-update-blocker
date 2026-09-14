# Canonical build.ps1 template (project-local icon, Au3Check + Aut2Exe)
# Copy into src\<project>\build.ps1 and replace placeholders.
# Write-Host messages are English-only (safe on GBK Windows / PS 5.1 without BOM).

$ErrorActionPreference = "Stop"
$ProjectRoot = Join-Path $PSScriptRoot "..\.."
$AutoItRoot = Join-Path $ProjectRoot "autoit-tool"

$Au3Src   = Join-Path $PSScriptRoot "wechat-update-blocker.au3"
$OutExe   = Join-Path $ProjectRoot "dist\wechat-update-blocker.exe"
$Icon     = Join-Path $PSScriptRoot "wechat-update-blocker.ico"
$Compiler = Join-Path $AutoItRoot "Aut2Exe\Aut2exe_x64.exe"
$Checker  = Join-Path $AutoItRoot "Au3Check.exe"

if (-not (Test-Path (Join-Path $ProjectRoot "dist"))) {
    New-Item -Path (Join-Path $ProjectRoot "dist") -ItemType Directory | Out-Null
}

Write-Host "[Check] Au3Check ..." -ForegroundColor Cyan
& $Checker $Au3Src
if ($LASTEXITCODE -ne 0) {
    Write-Host "Syntax check failed!" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit $LASTEXITCODE
}

Write-Host "[Build] wechat-update-blocker.au3 ..." -ForegroundColor Cyan
& $Compiler /in $Au3Src /out $OutExe /icon $Icon /x64 /comp 4

if ($LASTEXITCODE -ne 0) {
    Write-Host "Build failed!" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit $LASTEXITCODE
}

Write-Host "[Done] $OutExe" -ForegroundColor Green
