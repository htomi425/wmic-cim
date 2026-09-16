#Requires -Version 5.1
<#
.SYNOPSIS
  Install the WMIC → CIM wrapper onto the current user PATH.

.DESCRIPTION
  Copies wmic.ps1 / wmic.cmd / aliases.json to %LOCALAPPDATA%\wmic-cim
  and prepends that directory to the user PATH. Also appends a Set-Alias
  to the current user's PowerShell profile so `wmic` wins over a leftover
  System32\wmic.exe inside PowerShell.

.NOTES
  管理者権限は不要。アンインストールは Uninstall.ps1。
#>
[CmdletBinding()]
param(
    [switch]$AddProfileAlias
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$src = $PSScriptRoot
$dest = Join-Path $env:LOCALAPPDATA 'wmic-cim'
New-Item -ItemType Directory -Force -Path $dest | Out-Null

foreach ($name in @('wmic.ps1', 'wmic.cmd', 'aliases.json', 'Uninstall.ps1', 'README.md', 'SPEC.md')) {
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

$wantAlias = $AddProfileAlias
if (-not $PSBoundParameters.ContainsKey('AddProfileAlias')) { $wantAlias = $true }

if ($wantAlias) {
    $profiles = @()
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $profiles += $PROFILE.CurrentUserAllHosts
    }
    else {
        $profiles += $PROFILE
    }
    # Windows PowerShell 5.1 profile AND PowerShell 7 profile if present
    $profiles += Join-Path $HOME 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'
    $profiles += Join-Path $HOME 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'
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

$exe = Get-Command wmic.exe -ErrorAction SilentlyContinue
Write-Host "Installed to $dest"
Write-Host "User PATH updated. 新しいターミナルを開いて ``wmic os get caption`` を試してください。"
if ($exe) {
    Write-Warning "wmic.exe がまだあります: $($exe.Source). cmd.exe では .exe が .cmd より先に解決されます。PowerShell ではプロファイルの Set-Alias が優先されます。完全に差し替えるなら Windows の「WMIC」オプション機能を外してください。"
}
