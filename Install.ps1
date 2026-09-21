#Requires -Version 5.1
<#
.SYNOPSIS
  Install the WMIC → CIM wrapper onto the current user PATH.

.DESCRIPTION
  wmic.exe が無いときだけ入れます。ある環境では公式 WMIC を使えばよく、
  このラッパーはコピーしません。

.NOTES
  管理者権限は不要。アンインストールは Uninstall.ps1。
#>
param(
    [switch]$Force,
    [switch]$AddProfileAlias
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NativeWmic {
    $candidates = @(
        (Join-Path $env:SystemRoot 'System32\wbem\wmic.exe')
        (Join-Path $env:SystemRoot 'Sysnative\wbem\wmic.exe')
        (Join-Path $env:SystemRoot 'System32\wmic.exe')
    )
    foreach ($p in $candidates) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    $cmd = Get-Command wmic.exe -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -and ($cmd.Source -notmatch 'wmic-cim')) { return $cmd.Source }
    return $null
}

$native = Get-NativeWmic
if ($native -and -not $Force) {
    Write-Host "wmic.exe があります: $native"
    Write-Host '公式 WMIC が使えるので、このラッパーは入れません。'
    Write-Host '無理に入れる場合だけ:  .\Install.ps1 -Force'
    exit 0
}

$src = $PSScriptRoot
$dest = Join-Path $env:LOCALAPPDATA 'wmic-cim'
New-Item -ItemType Directory -Force -Path $dest | Out-Null

foreach ($name in @('wmic.ps1', 'wmic.cmd', 'aliases.json', 'HELP.txt', 'Uninstall.ps1', 'README.md', 'SPEC.md')) {
    $from = Join-Path $src $name
    if (Test-Path -LiteralPath $from) {
        Copy-Item -LiteralPath $from -Destination (Join-Path $dest $name) -Force
    }
}

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not $userPath) { $userPath = '' }
$parts = @($userPath -split ';' | Where-Object { $_ -and ($_ -ne $dest) })
$newPath = ($dest, $parts) -join ';'
[Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
$env:Path = $dest + ';' + $env:Path

if ($AddProfileAlias) {
    $profiles = @()
    $profiles += Join-Path $HOME 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'
    $profiles += Join-Path $HOME 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'
    if ($PROFILE) { $profiles += $PROFILE }
    $profiles = $profiles | Select-Object -Unique

    $aliasLine = 'Set-Alias -Name wmic -Value (Join-Path $env:LOCALAPPDATA ''wmic-cim\wmic.ps1'')'
    $marker = '# wmic-cim'
    foreach ($prof in $profiles) {
        $dir = Split-Path $prof -Parent
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        $existing = ''
        if (Test-Path -LiteralPath $prof) {
            $existing = Get-Content -LiteralPath $prof -Raw -ErrorAction SilentlyContinue
        }
        if ($existing -and $existing.Contains($marker)) { continue }
        Add-Content -LiteralPath $prof -Value "`r`n$marker`r`n$aliasLine`r`n" -Encoding UTF8
    }
}

Write-Host "Installed to $dest"
Write-Host '新しいターミナルで  wmic os get caption  を試してください。'
if ($native -and $Force) {
    Write-Warning "wmic.exe が残っています: $native 。cmd では .exe が先に解決されます。"
}
