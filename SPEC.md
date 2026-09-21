# CIMIC 仕様

WMIC コマンドラインを **CIM cmdlet** に通すラッパーの仕様です。バックエンドは `Get-WmiObject` でも COM (`SWbemLocator`) でもなく、`Get-CimInstance` / `Invoke-CimMethod` などです。

この文書が「何を受け、何を実行し、何を拒否するか」の正本です。未記載の挙動は未定義なので、必要なら issue にしてください。

実装: [`wmic.ps1`](wmic.ps1)  
カタログ: [`aliases.json`](aliases.json)

## 1. 対象環境

| 項目 | 値 |
| --- | --- |
| OS | Windows 8 / Server 2012 以降（CIM cmdlet があること） |
| シェル | Windows PowerShell 5.1 または PowerShell 7（Windows） |
| スクリプトの文字コード | UTF-8 **BOM 付き**（5.1 が Shift-JIS と誤認しないため。システム UTF-8 設定は不要） |
| ローカル API | 常に CIM。プロセス内で Winmgmt に届く |
| リモート API | 既定 WS-Man（WinRM）。接続失敗時だけ DCOM |

WMI リポジトリ（Win32_* の中身）は COM でも CIM でも同じです。違うのはクライアントとリモートのプロトコルです。

## 2. 受け付ける構文

```
wmic [スイッチ] <エイリアス | PATH クラス> [where <WQL>] <動詞> [引数]
```

引数なし起動は対話モード。プロンプトは `wmic:root\cimv2>`。`quit` / `exit` / `q` で終了。

`/?` は [HELP.txt](HELP.txt) を出すだけです。公式 WMIC のヘルプ複製でも SPEC の再掲でもありません。エイリアス個別 (`wmic os /?`) は `aliases.json` からクラス名と BRIEF 列だけ出します。動きの正本はこのファイルです。

### 2.1 スイッチ

| スイッチ | 意味 | WMIC 互換 |
| --- | --- | --- |
| `/NODE:host[,host2]` | リモート対象。カンマ区切りで複数可 | 互換 |
| `/NAMESPACE:root\cimv2` | CIM 名前空間。`\` と `/` どちらでも可 | 互換 |
| `/USER:name` | 資格情報。`/NODE` 必須 | 互換（用途をリモートに限定） |
| `/PASSWORD:secret` | 平文パスワード。非推奨 | 互換（残しているだけ） |
| `/FORMAT:TABLE\|LIST\|CSV\|VALUE\|XML` | 出力形式 | ほぼ互換。MOF は XML 扱い |
| `/OUTPUT:file` | 標準出力を上書き保存 | 互換 |
| `/APPEND:file` | 追記 | 互換 |
| `/PROTOCOL:AUTO\|WSMAN\|DCOM` | `/NODE` のプロトコル | **CIMIC 拡張**（WMIC に無い） |

優先順位: **`/PROTOCOL` > 環境変数 `WMIC_PROTOCOL` > `AUTO`**。

`/PASSWORD` より `/USER` だけ指定してプロンプトを出す方が安全です。

### 2.2 動詞

| 動詞 | CIM | 備考 |
| --- | --- | --- |
| `GET`（省略時も GET） | `Get-CimInstance` + 列選択 | エイリアスの defaultGet を使う |
| `LIST [BRIEF\|FULL]` | 同上 | BRIEF はエイリアスの brief 列 |
| `SET name=value,...` | `Set-CimInstance` | |
| `CALL method [args]` | `Invoke-CimMethod` | クラスの in パラメータ順で位置引数を埋める |
| `CREATE name=value,...` | `New-CimInstance` | |
| `DELETE` | `Remove-CimInstance` | WHERE 必須 |
| `ASSOCIATORS` / `ASSOC` | `Get-CimAssociatedInstance` | |

`PATH Win32_Foo` は未登録クラスでも通ります。エイリアス表は `aliases.json` です。

WHERE の文字列は WQL では単引用です。公式 WMIC の `name="explorer.exe"` は cmd が引用を剥がして `name=explorer.exe` になることが多いので、ラッパーが `'explorer.exe'` を補います。数字・TRUE/FALSE/NULL はそのままです。

## 3. `/NODE` とプロトコル

ここが旧 WMIC（常に DCOM）と違う点です。クライアントは CIM のまま、セッションの作り方だけ変えます。`-ComputerName` は使いません（CIM ではそれが常に WS-Man になるため）。

### 3.1 判定

| 対象 | セッション | プロトコル |
| --- | --- | --- |
| `/NODE` なし | 作らない | プロセス内 |
| `.` / `localhost` / `127.0.0.1` / `::1` / 自ホスト名 | 作らない | プロセス内（WinRM 自己接続を避ける） |
| それ以外 + `AUTO`（既定） | `New-CimSession` | **WS-Man を最大 5 秒 → 接続失敗時だけ DCOM** |
| `/PROTOCOL:WSMAN` | `New-CimSession` | WS-Man のみ。落とさない |
| `/PROTOCOL:DCOM` | `New-CimSession -SessionOption Dcom` | DCOM のみ。WinRM を試さない |

`/NODE:a,b` は **ホストごとに** セッションを作ります。片方が WS-Man、もう片方が DCOM、があり得ます。

`/NODE:.,HOST` のようにローカルとリモートが混ざるときは、ローカルはプロセス内、リモートはセッション、の 2 本を走らせて結果を連結します。

### 3.2 AUTO が DCOM に落とす条件

落とすのは **接続・プロトコル失敗** だけです。

落とす例:

- WinRM サービスが止まっている / 未構成
- タイムアウト（WS-Man 側は `OperationTimeoutSec 5`）
- メッセージや HRESULT に `WinRM` / `WSMan` / `0x8033xxxx` が付くもの
- 「RPC server is unavailable」「The client cannot connect」

**落とさない** 例（同じエラーをそのまま返す）:

- クラスが無い
- WQL / WHERE が不正
- 0 件
- Access Denied（権限エラーを DCOM 再試行で隠さない）

両方死んだときは両方のメッセージを出して失敗します。

```
/NODE:HOST : WS-Man 失敗 (...); DCOM も失敗 (...)
```

DCOM に落ちたときは **そのホストで一度だけ** 警告します。

```
WARNING: /NODE:HOST : WS-Man に失敗したため DCOM で接続しました。固定するなら /protocol:dcom
```

対話モードでは勝ったプロトコルをプロセス内で覚えます。2 行目以降は WS-Man の 5 秒を踏みません。

### 3.3 DCOM セッションの既定

WMIC の既定に寄せます。

```powershell
New-CimSessionOption -Protocol Dcom -Impersonation Impersonate -PacketPrivacy
```

| 項目 | 値 |
| --- | --- |
| Impersonation | Impersonate |
| Auth | Packet Privacy |
| 資格情報 | `New-CimSession -Credential` のみ。`Get-CimInstance -CimSession` には付けない |

`/IMPLEVEL` / `/AUTHLEVEL` はまだマップしません。今は上の既定固定です。

### 3.4 ポート

| プロトコル | 相手が開けるもの |
| --- | --- |
| WS-Man | 5985 (HTTP) / 5986 (HTTPS) |
| DCOM | 135 + 動的 RPC |

フォールバックしても、相手のファイアウォールが RPC を切っていれば DCOM も失敗します。ラッパーはポートを開けません。

### 3.5 資格情報

`/USER` と `/PASSWORD` は **リモートセッション作成時だけ** 使います。`/NODE` 無しの `/USER` は警告して無視します。

## 4. 安全側に倒しているところ

これらは WMIC より厳しいです。意図的です。

| 操作 | 挙動 |
| --- | --- |
| WHERE 無しの `DELETE` | 拒否 |
| `DATAFILE` / `FSDIR` / `NTEVENT` を WHERE 無し | 拒否（全ディスク・全イベントになる） |
| `PRODUCT` (`Win32_Product`) | 実行はする。列挙のたびに MSI 整合性チェックが走るので警告 |
| `/PASSWORD` | 受け付けるが平文。ログに残る |

## 5. 出力

| `/FORMAT` / 動詞 | 出力 |
| --- | --- |
| 省略時 GET | 空白区切りテーブル。列名は CIM の正式名 (`caption` → `Caption`) |
| `LIST BRIEF` | テーブル。列はエイリアスの BRIEF（公式 WMIC は BRIEF に TABLE スタイルシートを使う） |
| `LIST` / `LIST FULL` / `VALUE` | `Name=Value` |
| `/FORMAT:LIST` を BRIEF に付けたとき | `Name=Value`（公式と同じ上書き） |
| `CSV` | `ConvertTo-Csv -NoTypeInformation` |
| `XML` | `ConvertTo-Xml -As String`（WMIC の XML とスキーマは違う） |
| 日時 | `DateTime` を `yyyyMMddHHmmss.ffffffzzz` に寄せる |
| 論理値 | `TRUE` / `FALSE` |

CIM が変換した `DateTime` を、表示だけ DMTF 風に戻しています。バッチが文字列比較している場合の救済です。完全一致は保証しません。

## 6. 環境変数

| 名前 | 値 | 意味 |
| --- | --- | --- |
| `WMIC_PROTOCOL` | `AUTO` / `WSMAN` / `DCOM` | `/PROTOCOL` が無いときの既定 |

バッチの途中にスイッチを差し込めないとき用です。`/PROTOCOL` があればそちらが勝ちます。

```bat
set WMIC_PROTOCOL=DCOM
wmic /node:OLDHOST os get caption
```

## 7. 例

```bat
wmic os get caption,version
wmic process where name="explorer.exe" get processid
wmic /node:. os get caption
wmic /node:HOST os get caption,version
wmic /protocol:dcom /node:HOST os get caption
wmic /protocol:wsman /node:HOST os get caption
wmic /node:HOST1,HOST2 cpu list brief
wmic /node:HOST /user:DOMAIN\admin os get caption
wmic process call create "notepad.exe"
```

プレビュー用に生成される PowerShell は、ラッパー内部のセッション キャッシュを展開した **等価なワンショット** です。本番の `wmic.ps1` はセッションを使い回し、対話終了時に閉じます。

## 8. 明示的にやらないこと

- `Get-WmiObject` / `SWbemLocator` / 生 COM へのフォールバック
- ローカルまで DCOM セッションにする
- Access Denied を DCOM で再試行する
- ファイアウォールや WinRM の自動構成
- WMIC の `/TRANSLATE`、`/INTERACTIVE`、`/FAILFAST`、`/RECORD` の完全再現
- `/FORMAT:HFORM|HTABLE|MOF` のピクセル一致
- Linux / 非 Windows の CIM サーバ

## 9. 失敗したときに見ること

1. ローカルで `wmic os get caption` が通るか（CIM そのもの）
2. `wmic /protocol:wsman /node:HOST os get caption`（WinRM 単体）
3. `wmic /protocol:dcom /node:HOST os get caption`（DCOM 単体）
4. 相手の 5985/5986 または 135+RPC
5. `/USER` の資格情報がセッション作成に渡っているか

2 が失敗して 3 が通るのが、AUTO フォールバックが想定している形です。
