# wmic-cim

`wmic.exe` が **無い** 環境向けの CIM 互換ラッパーです。Windows 11 24H2 / Windows Server 2025 では WMIC が既定で入りません。

公式 `wmic.exe` があるマシンでは不要です。`Install.ps1` は exe を見つけると何もしません。

既存のバッチがまだ

```bat
wmic os get caption,version
wmic process where name="explorer.exe" get processid
wmic /node:HOST os get caption
```

と書いているなら、このラッパーが同じコマンドラインを CIM cmdlet に通します。

何を受け、何を拒否し、リモートをどう繋ぐかは [SPEC.md](SPEC.md) が正本です。`wmic /?` は [HELP.txt](HELP.txt) だけ出します。

リポジトリ: <https://github.com/htomi425/wmic-cim>

## 入れ方

PowerShell（ユーザー権限で可）:

```powershell
git clone https://github.com/htomi425/wmic-cim.git
cd wmic-cim
Set-ExecutionPolicy -Scope Process Bypass
.\Install.ps1
```

`wmic.exe` があると「入れません」と出て終わります。テスト目的で重ねるときだけ `-Force`。

`%LOCALAPPDATA%\wmic-cim` にコピーし、そのフォルダをユーザー PATH の先頭に足します。起動ファイルは x64 の `wmic.exe`（`wmic-stub.c`）で、同じフォルダの `wmic.ps1` に引数を渡すだけです。`where wmic.exe` もここを見ます。System32 には置きません。

新しいターミナルを開いて:

```powershell
wmic os get caption,version
wmic cpu list brief
wmic /?
```

外すとき:

```powershell
& "$env:LOCALAPPDATA\wmic-cim\Uninstall.ps1"
```
