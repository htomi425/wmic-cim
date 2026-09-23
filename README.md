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

`%LOCALAPPDATA%\wmic-cim` にコピーし、そのフォルダをユーザー PATH の先頭に足します。入るのは `wmic.exe` と `wmic.ps1` です。ソースの `wmic-stub.c` は置きません。`wmic.exe` は x64 の起動専用で、同じフォルダの `wmic.ps1` に引数を渡すだけです。`where wmic.exe` もここを見ます。System32 には置きません。

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

## wmic.exe のビルド

処理はすべて `wmic.ps1` です。`wmic.exe` は `wmic-stub.c` の転送スタブで、リポジトリに同梱しているバイナリは次で作っています。

Zig 0.14.1（Windows でも Linux でも同じ）:

```text
zig cc -target x86_64-windows-gnu -O2 -s -o wmic.exe wmic-stub.c
```

この組み合わせの SHA-256:

```text
wmic-stub.c  9b0245b9b0a538ec47bda82287f1e682041f20e0caf552a2a86e12ae121f3a58
wmic.exe     e647c70134ea510658f87e0cd9796d1d24a4465c0fb28e4d2917503323ae8b94
```

ソースかコンパイラを変えると exe のハッシュは変わります。同梱バイナリを信用しないときは、同じコマンドで作り直してから `Install.ps1` してください。

MinGW-w64 でも作れます。ハッシュは Zig 版と一致しません。

```text
x86_64-w64-mingw32-gcc -O2 -s -o wmic.exe wmic-stub.c
```
