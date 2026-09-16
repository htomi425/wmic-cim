#Requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$dest = Join-Path $env:LOCALAPPDATA 'wmic-cim'

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath) {
    $parts = @($userPath -split ';' | Where-Object { $_ -and ($_ -ne $dest) })
    [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
}

$profiles = @(
    Join-Path $HOME 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'
    Join-Path $HOME 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'
)
if ($PROFILE) { $profiles += $PROFILE }
$profiles = $profiles | Select-Object -Unique

foreach ($prof in $profiles) {
    if (-not (Test-Path -LiteralPath $prof)) { continue }
    $lines = Get-Content -LiteralPath $prof
    $keep = New-Object System.Collections.Generic.List[string]
    $skip = $false
    foreach ($line in $lines) {
        if ($line -eq '# wmic-cim') { $skip = $true; continue }
        if ($skip) {
            if ($line -match '^\s*Set-Alias -Name wmic') { $skip = $false; continue }
            $skip = $false
        }
        $keep.Add($line)
    }
    Set-Content -LiteralPath $prof -Value $keep -Encoding UTF8
}

if (Test-Path -LiteralPath $dest) {
    Remove-Item -LiteralPath $dest -Recurse -Force
}

Write-Host 'wmic-cim を外しました。新しいターミナルを開いて PATH を更新してください。'
