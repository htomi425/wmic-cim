# wmic-cim

廃止された `wmic.exe` を **CIM** に通す互換ラッパーです。

Windows 11 24H2 / Windows Server 2025 では WMIC が既定で入りません。既存のバッチや手順書がまだ

```bat
wmic os get caption,version
wmic process where name="explorer.exe" get processid
```

と書いているなら、このラッパーが同じコマンドラインを受け取って

```powershell
Get-CimInstance -ClassName Win32_OperatingSystem | Select-Object Caption, Version
Get-CimInstance -ClassName Win32_Process -Filter "name='explorer.exe'" | Select-Object ProcessId
```

を実行します。

リポジトリ: <https://github.com/htomi425/wmic-cim>

## 入れ方

PowerShell（ユーザー権限で可）:

```powershell
git clone https://github.com/htomi425/wmic-cim.git
cd wmic-cim
Set-ExecutionPolicy -Scope Process Bypass
.\Install.ps1
```

`%LOCALAPPDATA%\wmic-cim` にコピーし、ユーザー PATH の先頭へ `wmic.cmd` を置きます。PowerShell プロファイルには `Set-Alias wmic` を足すので、残存する `System32\wmic.exe` よりこちらが優先されます。

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

## 動き

| WMIC | CIM |
| --- | --- |
| `alias` (`os`, `process`, `service`, …) | `Win32_*` / `CIM_*` クラス |
| `PATH Win32_Foo` | `-ClassName Win32_Foo` |
| `where ...` | `-Filter` (WQL) |
| `GET` / `LIST` | `Get-CimInstance` |
| `SET` | `Set-CimInstance` |
| `CALL` | `Invoke-CimMethod`（クラスの in パラメータを実行時に解決） |
| `CREATE` | `New-CimInstance` |
| `DELETE` | `Remove-CimInstance` |
| `/NODE` `/NAMESPACE` `/USER` | `-ComputerName` `-Namespace` `-Credential` |
| `/FORMAT:LIST\|CSV\|VALUE\|TABLE` | ほぼ同じ見た目の出力 |

エイリアス表は [`aliases.json`](aliases.json) です。未登録クラスでも `PATH` で直接指定できます。

## 安全側に倒しているところ

- **WHERE 無しの `DELETE`** は拒否します。
- **`DATAFILE` / `FSDIR` / `NTEVENT`** は WHERE 無しでは走りません（全ディスク・全イベントの列挙になるため）。
- **`PRODUCT` (`Win32_Product`)** は動きますが、列挙のたびに MSI の整合性チェックが走るので警告を出します。`Get-Package` の方が安全です。
- `/PASSWORD` は互換のため残していますが、平文です。`/USER` だけ指定してプロンプトにした方がよいです。

## インタラクティブ

引数なしで起動すると旧 WMIC に近い REPL になります。

```
wmic:root\cimv2>
```

`quit` で抜けます。

## 要件

- Windows 8 / Server 2012 以降（CIM cmdlet が載っていること）
- Windows PowerShell 5.1 または PowerShell 7
- 管理者である必要はありません（リモート `/NODE` や一部の `CALL` は権限が要ることがあります）

## ライセンス

MIT
