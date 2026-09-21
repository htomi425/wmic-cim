# wmic-cim

廃止された `wmic.exe` を **CIM** に通す互換ラッパーです。

Windows 11 24H2 / Windows Server 2025 では WMIC が既定で入りません。既存のバッチや手順書がまだ

```bat
wmic os get caption,version
wmic process where name="explorer.exe" get processid
wmic /node:HOST os get caption
```

と書いているなら、このラッパーが同じコマンドラインを受け取って CIM cmdlet を実行します。

**何を受け、何を拒否し、リモートをどう繋ぐか** は [SPEC.md](SPEC.md) が正本です。`wmic /?` は [HELP.txt](HELP.txt) を出すだけで、SPEC の再掲ではありません。

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
| `/NODE` | `New-CimSession`。既定は WS-Man、接続失敗時だけ DCOM |
| `/PROTOCOL` | CIMIC 拡張。`AUTO` / `WSMAN` / `DCOM` |
| `/NAMESPACE` `/USER` | `-Namespace` / セッションの `-Credential` |
| `/FORMAT:LIST\|CSV\|VALUE\|TABLE` | ほぼ同じ見た目の出力 |

エイリアス表は [`aliases.json`](aliases.json) です。未登録クラスでも `PATH` で直接指定できます。

リモートの判定表・落とすエラー / 落とさないエラーは [SPEC.md §3](SPEC.md) にあります。短く言うと:

- ローカルと `.` / `localhost` はセッションを作りません
- `/NODE:HOST` は WS-Man を 5 秒試し、WinRM 系の失敗だけ DCOM に落とします
- クラス不正・WQL 不正・Access Denied では落としません
- 固定するなら `/protocol:dcom` または環境変数 `WMIC_PROTOCOL`

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

`quit` で抜けます。リモートセッションはプロセス内で使い回し、終了時に閉じます。

## 要件

- Windows 8 / Server 2012 以降（CIM cmdlet が載っていること）
- Windows PowerShell 5.1 または PowerShell 7
- 管理者である必要はありません（リモート `/NODE` や一部の `CALL` は権限が要ることがあります）

## 文字コード

`.ps1` は **UTF-8 BOM 付き** です。Windows PowerShell 5.1 は BOM が無いと、日本語 Windows ではスクリプトを Shift-JIS として読みます。その結果、「ベータ: ワールドワイド言語サポートで Unicode UTF-8 を使用」がオフだとパースエラーで動きません。

この配布物はその設定を必要としません。すでに入れている場合は `Install.ps1` をもう一度実行してファイルを上書きしてください。

PowerShell 7 (`pwsh`) は BOM 無し UTF-8 も読めます。

## ライセンス

MIT
