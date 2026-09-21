#Requires -Version 5.1
<#
.SYNOPSIS
  WMIC compatibility wrapper backed by CIM cmdlets.

.DESCRIPTION
  Accepts classic WMIC command lines and dispatches them to
  Get-CimInstance / Set-CimInstance / Invoke-CimMethod /
  Remove-CimInstance / New-CimInstance.

  Drop-in for environments where wmic.exe was removed (Windows 11 24H2 /
  Windows Server 2025) or the WMIC optional feature is not installed.

.EXAMPLE
  wmic os get caption,version

.EXAMPLE
  wmic process where name="explorer.exe" get processid,workingsetsize

.EXAMPLE
  wmic service where startmode="auto" get name,state

.NOTES
  Project: https://github.com/htomi425/wmic-cim
  Spec:    SPEC.md  (受け付ける構文、拒否条件、/NODE の動き)
#>
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$WmicArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AliasDoc = $null
$script:DefaultNamespace = 'root/cimv2'
$script:CimSessionCache = @{}
$script:NodeProtocol = @{}
$script:DcomWarned = @{}
$script:KeepCimSessions = $false

function Get-NoteProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function ConvertTo-WmicList {
    param($Value)
    $out = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Value) { return , $out }
    if ($Value -is [string]) {
        $out.Add($Value)
        return , $out
    }
    if ($Value -is [System.Collections.IList]) {
        foreach ($item in $Value) { $out.Add($item) }
        return , $out
    }
    $out.Add($Value)
    return , $out
}

function Get-WmicLen {
    param($Value)
    if ($null -eq $Value) { return 0 }
    if ($Value -is [string]) { return 1 }
    if ($Value -is [System.Collections.ICollection]) { return [int]$Value.Count }
    return 1
}

function Get-WmicAliasDocument {
    if ($null -ne $script:AliasDoc) { return $script:AliasDoc }
    $path = Join-Path $PSScriptRoot 'aliases.json'
    if (-not (Test-Path -LiteralPath $path)) {
        throw "aliases.json が見つかりません: $path"
    }
    $utf8 = New-Object System.Text.UTF8Encoding $true
    $raw = [System.IO.File]::ReadAllText($path, $utf8)
    if ($raw.Length -gt 0 -and [int][char]$raw[0] -eq 0xFEFF) { $raw = $raw.Substring(1) }
    $script:AliasDoc = $raw | ConvertFrom-Json
    return $script:AliasDoc
}

function Get-WmicAliasInfo {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    $doc = Get-WmicAliasDocument
    $prop = $doc.PSObject.Properties | Where-Object { $_.Name -eq $Name.ToUpperInvariant() }
    if ($prop) { return $prop.Value }
    foreach ($p in $doc.PSObject.Properties) {
        if ($p.Value.className -and $p.Value.className -eq $Name) { return $p.Value }
    }
    return $null
}

function Get-WmicTokens {
    param([string]$Line)
    $tokens = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Line)) { return , $tokens }
    $i = 0
    $s = $Line
    while ($i -lt $s.Length) {
        while ($i -lt $s.Length -and [char]::IsWhiteSpace($s[$i])) { $i++ }
        if ($i -ge $s.Length) { break }
        $ch = $s[$i]
        if ($ch -eq [char]34 -or $ch -eq [char]39) {
            $q = $ch
            $i++
            $buf = New-Object System.Text.StringBuilder
            while ($i -lt $s.Length -and $s[$i] -ne $q) {
                [void]$buf.Append($s[$i])
                $i++
            }
            if ($i -lt $s.Length -and $s[$i] -eq $q) { $i++ }
            $tokens.Add($buf.ToString())
            continue
        }
        $buf = New-Object System.Text.StringBuilder
        while ($i -lt $s.Length -and -not [char]::IsWhiteSpace($s[$i])) {
            [void]$buf.Append($s[$i])
            $i++
        }
        $tokens.Add($buf.ToString())
    }
    return , $tokens
}

function Convert-WqlLiteral {
    param([string]$Val)
    $v = $Val.Trim()
    if ($v.Length -ge 2 -and $v.StartsWith("'") -and $v.EndsWith("'")) { return $v }
    if ($v.Length -ge 2 -and $v.StartsWith('"') -and $v.EndsWith('"')) {
        return ("'" + $v.Substring(1, $v.Length - 2).Replace("'", "''") + "'")
    }
    if ($v -match '^(TRUE|FALSE|NULL)$') { return $v }
    if ($v -match '^[+-]?\d+$') { return $v }
    return ("'" + $v.Replace("'", "''") + "'")
}

function Split-WqlTop {
    param([string]$Expr, [string]$Op)
    $parts = New-Object System.Collections.Generic.List[string]
    $buf = New-Object System.Text.StringBuilder
    $depth = 0
    $i = 0
    $s = $Expr
    $upper = $s.ToUpperInvariant()
    $opLen = $Op.Length
    while ($i -lt $s.Length) {
        $ch = $s[$i]
        if ($ch -eq [char]40) { $depth++; [void]$buf.Append($ch); $i++; continue }
        if ($ch -eq [char]41) { $depth--; [void]$buf.Append($ch); $i++; continue }
        if ($ch -eq [char]39 -or $ch -eq [char]34) {
            $q = $ch
            [void]$buf.Append($ch)
            $i++
            while ($i -lt $s.Length -and $s[$i] -ne $q) {
                [void]$buf.Append($s[$i])
                $i++
            }
            if ($i -lt $s.Length) { [void]$buf.Append($s[$i]); $i++ }
            continue
        }
        if ($depth -eq 0 -and $i + $opLen -le $s.Length -and $upper.Substring($i, $opLen) -eq $Op) {
            $beforeOk = ($i -eq 0) -or [char]::IsWhiteSpace($s[$i - 1])
            $afterOk = ($i + $opLen -ge $s.Length) -or [char]::IsWhiteSpace($s[$i + $opLen])
            if ($beforeOk -and $afterOk) {
                $parts.Add($buf.ToString().Trim())
                [void]$buf.Clear()
                $i += $opLen
                continue
            }
        }
        [void]$buf.Append($ch)
        $i++
    }
    $tail = $buf.ToString().Trim()
    if ($tail) { $parts.Add($tail) }
    return $parts
}

function Convert-WqlExpr {
    param([string]$Expr)
    $e = $Expr.Trim()
    if (-not $e) { return $e }
    if ($e.StartsWith('(') -and $e.EndsWith(')') -and $e.Length -ge 2) {
        return ('(' + (Convert-WqlExpr $e.Substring(1, $e.Length - 2)) + ')')
    }
    $orParts = @(Split-WqlTop $e 'OR')
    if ($orParts.Count -gt 1) {
        return (($orParts | ForEach-Object { Convert-WqlExpr $_ }) -join ' OR ')
    }
    $andParts = @(Split-WqlTop $e 'AND')
    if ($andParts.Count -gt 1) {
        return (($andParts | ForEach-Object { Convert-WqlExpr $_ }) -join ' AND ')
    }
    $m = [regex]::Match($e, '^(?i)([A-Za-z_][\w.]*)\s*(<>|!=|<=|>=|=|<|>|LIKE)\s*(.*)$')
    if (-not $m.Success) { return $e }
    return ($m.Groups[1].Value + ' ' + $m.Groups[2].Value + ' ' + (Convert-WqlLiteral $m.Groups[3].Value))
}

function ConvertTo-WqlFilter {
    param([string]$Where)
    if ([string]::IsNullOrWhiteSpace($Where)) { return $null }
    $s = $Where.Trim()
    if ($s.StartsWith('(') -and $s.EndsWith(')') -and $s.Length -ge 2) {
        $s = $s.Substring(1, $s.Length - 2).Trim()
    }
    # WMIC allows name="explorer.exe". cmd/pwsh often strip those quotes, leaving a bare
    # token that WQL rejects. Convert remaining doubles, then quote bare string values.
    $s = [regex]::Replace($s, '"([^"]*)"', { param($m) "'" + ($m.Groups[1].Value.Replace("'", "''")) + "'" })
    $s = [regex]::Replace($s, '\s*==\s*', '=')
    return (Convert-WqlExpr $s)
}

function Split-WmicCsv {
    param([string[]]$Parts)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($p in $Parts) {
        foreach ($bit in ($p -split ',')) {
            $t = $bit.Trim()
            if ($t) { $out.Add($t) }
        }
    }
    return , $out
}

function Parse-WmicPairs {
    param([string[]]$Parts)
    $joined = ($Parts -join ' ')
    $out = @()
    $re = [regex]'([A-Za-z_][\w.]*)\s*=\s*(?:"([^"]*)"|''([^'']*)''|([^,\s]+))'
    foreach ($m in $re.Matches($joined)) {
        $val = $m.Groups[2].Value
        if (-not $val) { $val = $m.Groups[3].Value }
        if (-not $val) { $val = $m.Groups[4].Value }
        $out += [pscustomobject]@{ Name = $m.Groups[1].Value; Value = $val }
    }
    return $out
}

function Parse-WmicSwitchToken {
    param([string]$Token)
    if ([string]::IsNullOrWhiteSpace($Token)) { return $null }
    $t = $Token.Trim()
    if ($t -eq '/?' -or $t -eq '-?' -or $t -eq '-help' -or $t -eq '/help') {
        return @{ Name = '?'; Value = $true }
    }
    if ($Token -notmatch '^/([A-Za-z][A-Za-z0-9]*)(?::(.*))?$') { return $null }
    $name = $Matches[1].ToLowerInvariant()
    if ($null -eq $Matches[2]) {
        return @{ Name = $name; Value = $true }
    }
    $value = $Matches[2]
    if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
        $value = $value.Substring(1, $value.Length - 2)
    }
    return @{ Name = $name; Value = $value }
}

function Test-WmicVerb {
    param([string]$Token)
    if ([string]::IsNullOrWhiteSpace($Token)) { return $false }
    switch ($Token.ToUpperInvariant()) {
        'GET' { return $true }
        'LIST' { return $true }
        'SET' { return $true }
        'CALL' { return $true }
        'CREATE' { return $true }
        'DELETE' { return $true }
        'ASSOCIATORS' { return $true }
        'ASSOC' { return $true }
        default { return $false }
    }
}

function Parse-WmicLine {
    param([string]$Line)
    $parsed = [ordered]@{
        Raw         = $Line
        Switches    = @{}
        PathClass   = $null
        Alias       = $null
        Where       = $null
        Verb        = $null
        ListStyle   = $null
        Properties  = @()
        SetPairs    = @()
        CreatePairs = @()
        CallMethod  = $null
        CallArgs    = @()
        Help        = $false
    }
    $tokens = Get-WmicTokens $Line
    $i = 0
    if ($tokens.Count -gt 0 -and $tokens[0].ToLowerInvariant() -eq 'wmic') { $i = 1 }

    $eatSwitches = {
        while ($i -lt $tokens.Count) {
            $sw = Parse-WmicSwitchToken $tokens[$i]
            if ($null -eq $sw) { break }
            if ($sw.Name -eq '?' -or $sw.Name -eq 'help') {
                $parsed.Help = $true
                $i++
                continue
            }
            $parsed.Switches[$sw.Name] = $sw.Value
            $i++
        }
    }

    & $eatSwitches
    if ($i -ge $tokens.Count) { return [pscustomobject]$parsed }

    $head = $tokens[$i]
    if ($head -eq '/?' -or $head.ToLowerInvariant() -eq '/help') {
        $parsed.Help = $true
        return [pscustomobject]$parsed
    }

    if ($head.ToLowerInvariant() -eq 'path') {
        $i++
        if ($i -ge $tokens.Count) { throw 'PATH の後にクラス名が必要です。例: path Win32_Process' }
        $cls = $tokens[$i]
        $colon = $cls.LastIndexOf(':')
        if ($colon -ge 0 -and $cls.Substring($colon + 1) -match '^(Win32_|CIM_)') {
            $cls = $cls.Substring($colon + 1)
        }
        $parsed.PathClass = $cls
        $i++
    }
    elseif (-not (Test-WmicVerb $head) -and -not (Parse-WmicSwitchToken $head)) {
        $parsed.Alias = $head
        $i++
    }

    & $eatSwitches

    if ($i -lt $tokens.Count -and $tokens[$i].ToLowerInvariant() -eq 'where') {
        $i++
        $whereParts = New-Object System.Collections.Generic.List[string]
        while ($i -lt $tokens.Count -and -not (Test-WmicVerb $tokens[$i]) -and -not (Parse-WmicSwitchToken $tokens[$i])) {
            $whereParts.Add($tokens[$i])
            $i++
        }
        $parsed.Where = ($whereParts -join ' ')
    }

    & $eatSwitches

    if ($i -lt $tokens.Count -and (Test-WmicVerb $tokens[$i])) {
        $v = $tokens[$i].ToUpperInvariant()
        if ($v -eq 'ASSOC') { $v = 'ASSOCIATORS' }
        $parsed.Verb = $v
        $i++
        $rest = New-Object System.Collections.Generic.List[string]
        while ($i -lt $tokens.Count) {
            $sw = Parse-WmicSwitchToken $tokens[$i]
            if ($sw) {
                if ($sw.Name -eq '?' -or $sw.Name -eq 'help') { $parsed.Help = $true; $i++; continue }
                $parsed.Switches[$sw.Name] = $sw.Value
                $i++
                continue
            }
            $rest.Add($tokens[$i])
            $i++
        }
        switch ($parsed.Verb) {
            'GET' { $parsed.Properties = Split-WmicCsv $rest }
            'LIST' {
                if ($rest.Count -gt 0) {
                    $parsed.ListStyle = $rest[0].ToUpperInvariant()
                    if ($rest.Count -gt 1) {
                        $tail = New-Object System.Collections.Generic.List[string]
                        for ($j = 1; $j -lt $rest.Count; $j++) { [void]$tail.Add($rest[$j]) }
                        $parsed.Properties = Split-WmicCsv $tail
                    }
                }
                else { $parsed.ListStyle = 'FULL' }
            }
            'SET' { $parsed.SetPairs = @(Parse-WmicPairs $rest) }
            'CREATE' { $parsed.CreatePairs = @(Parse-WmicPairs $rest) }
            'CALL' {
                if ($rest.Count -gt 0) {
                    $parsed.CallMethod = $rest[0]
                    if ($rest.Count -gt 1) {
                        $tail = New-Object System.Collections.Generic.List[string]
                        for ($j = 1; $j -lt $rest.Count; $j++) { [void]$tail.Add($rest[$j]) }
                        $parsed.CallArgs = Split-WmicCsv $tail
                    }
                }
            }
        }
    }

    if (-not $parsed.Verb -and ($parsed.Alias -or $parsed.PathClass) -and -not $parsed.Help) {
        $parsed.Verb = 'GET'
    }
    return [pscustomobject]$parsed
}

function Get-WmicSwitchValue {
    param($Parsed, [string]$Name)
    if ($Parsed.Switches.Contains($Name)) { return $Parsed.Switches[$Name] }
    return $null
}

function Resolve-WmicFormat {
    param($Parsed)
    $fmt = Get-WmicSwitchValue $Parsed 'format'
    if ($fmt -is [string]) {
        switch ($fmt.ToUpperInvariant()) {
            'LIST' { return 'LIST' }
            'CSV' { return 'CSV' }
            'VALUE' { return 'VALUE' }
            'XML' { return 'XML' }
            'MOF' { return 'XML' }
            'TABLE' { return 'TABLE' }
        }
    }
    if ($Parsed.Switches.Contains('value')) { return 'VALUE' }
    # Official WMIC: LIST BRIEF uses the TABLE stylesheet; LIST FULL uses LIST.
    if ($Parsed.Verb -eq 'LIST' -and $Parsed.ListStyle -eq 'BRIEF') { return 'TABLE' }
    if ($Parsed.Verb -eq 'LIST') { return 'LIST' }
    return 'TABLE'
}

function Resolve-WmicTarget {
    param($Parsed)
    $info = $null
    $className = $null
    if ($Parsed.PathClass) {
        $className = $Parsed.PathClass
        $info = Get-WmicAliasInfo $Parsed.PathClass
    }
    elseif ($Parsed.Alias) {
        $info = Get-WmicAliasInfo $Parsed.Alias
        if ($info) { $className = $info.className }
        else { $className = $Parsed.Alias }
    }
    $ns = $script:DefaultNamespace
    $rawNs = Get-WmicSwitchValue $Parsed 'namespace'
    if ($rawNs -is [string] -and $rawNs) {
        $ns = ($rawNs -replace '^\\\\', '' -replace '\\', '/')
    }
    elseif ($info -and $info.namespace) {
        $ns = $info.namespace
    }
    return @{ Info = $info; ClassName = $className; Namespace = $ns }
}

function Get-WmicSelectProperties {
    param($Parsed, $Info)
    if ((Get-WmicLen $Parsed.Properties) -gt 0) { return , (ConvertTo-WmicList $Parsed.Properties) }
    if ($Parsed.Verb -eq 'LIST' -and $Parsed.ListStyle -eq 'BRIEF' -and $Info) {
        return , (ConvertTo-WmicList (Get-NoteProperty $Info 'brief'))
    }
    if ($Parsed.Verb -eq 'LIST' -and ($Parsed.ListStyle -eq 'FULL' -or -not $Parsed.ListStyle)) {
        return $null
    }
    $dg = Get-NoteProperty $Info 'defaultGet'
    if ($null -ne $dg) { return , (ConvertTo-WmicList $dg) }
    return $null
}

function New-WmicQueryParams {
    param($Parsed, [string]$ClassName, [string]$Namespace)
    $p = @{ ClassName = $ClassName }
    if ($Namespace -and $Namespace -ne 'root/cimv2') { $p.Namespace = $Namespace }
    $filter = ConvertTo-WqlFilter $Parsed.Where
    if ($filter) { $p.Filter = $filter }
    return $p
}

function Get-WmicNodeList {
    param($Parsed)
    $node = Get-WmicSwitchValue $Parsed 'node'
    if (-not ($node -is [string] -and $node)) { return @() }
    return @($node -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Test-WmicLocalNode {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $true }
    $n = $Name.Trim()
    $n = $n.TrimStart('\')
    switch ($n.ToLowerInvariant()) {
        '.' { return $true }
        'localhost' { return $true }
        '127.0.0.1' { return $true }
        '::1' { return $true }
    }
    if ($n -and $env:COMPUTERNAME -and ($n -ieq $env:COMPUTERNAME)) { return $true }
    return $false
}

function Resolve-WmicProtocol {
    param($Parsed)
    $raw = Get-WmicSwitchValue $Parsed 'protocol'
    if (-not $raw) { $raw = $env:WMIC_PROTOCOL }
    if ($raw -is [string] -and $raw.Trim()) {
        switch ($raw.Trim().ToUpperInvariant()) {
            'DCOM'  { return 'Dcom' }
            'WSMAN' { return 'Wsman' }
            'WINRM' { return 'Wsman' }
            'AUTO'  { return 'Auto' }
            default { throw "/PROTOCOL は AUTO / WSMAN / DCOM のいずれかです: $raw" }
        }
    }
    return 'Auto'
}

function Get-WmicCredential {
    param($Parsed)
    $user = Get-WmicSwitchValue $Parsed 'user'
    $pass = Get-WmicSwitchValue $Parsed 'password'
    if (-not $user -and -not $pass) { return $null }
    if ($pass -is [string] -and $pass) {
        $sec = ConvertTo-SecureString $pass -AsPlainText -Force
        $userName = if ($user) { $user.ToString() } else { $env:USERNAME }
        return New-Object System.Management.Automation.PSCredential ($userName, $sec)
    }
    return Get-Credential -UserName $user
}

function Test-WmicWsmanFailure {
    param($ErrorRecord)
    $parts = New-Object System.Collections.Generic.List[string]
    if ($ErrorRecord) {
        [void]$parts.Add([string]$ErrorRecord.FullyQualifiedErrorId)
        $ex = $ErrorRecord.Exception
        $guard = 0
        while ($null -ne $ex -and $guard -lt 5) {
            [void]$parts.Add([string]$ex.Message)
            [void]$parts.Add([string]$ex.GetType().FullName)
            try { [void]$parts.Add(('HRESULT:{0:X8}' -f $ex.HResult)) } catch { }
            $ex = $ex.InnerException
            $guard++
        }
    }
    $blob = ($parts -join ' ')
    if ($blob -match 'WSMan|WinRM|WSMAN|WS-Management|CimJob|ResourceUnavailable|ConnectionErr|0x8033|HRESULT:8033|RPC server is unavailable|The client cannot connect|WinRM クライアント|WinRM client') {
        return $true
    }
    return $false
}

function Get-WmicSessionCacheKey {
    param([string]$ComputerName, [string]$UserName, [string]$Protocol)
    $u = if ($UserName) { $UserName } else { '' }
    return '{0}|{1}|{2}' -f $ComputerName.ToLowerInvariant(), $u.ToLowerInvariant(), $Protocol
}

function Get-WmicCachedSession {
    param([string]$Key)
    if (-not $script:CimSessionCache.ContainsKey($Key)) { return $null }
    $entry = $script:CimSessionCache[$Key]
    $session = $null
    if ($entry -is [hashtable] -and $entry.ContainsKey('Session')) { $session = $entry.Session }
    else { $session = $entry }
    if ($null -eq $session) { return $null }
    try {
        $id = $session.Id
        $alive = Get-CimSession -Id $id -ErrorAction Stop
        if ($alive) { return $session }
    }
    catch {
        $script:CimSessionCache.Remove($Key)
    }
    return $null
}

function New-WmicDcomSessionOption {
    return New-CimSessionOption -Protocol Dcom -Impersonation Impersonate -PacketPrivacy
}

function Connect-WmicCimSession {
    param(
        [string]$ComputerName,
        $Credential,
        [ValidateSet('Auto', 'Wsman', 'Dcom')]
        [string]$Protocol = 'Auto'
    )

    if (Test-WmicLocalNode $ComputerName) { return $null }

    $userName = ''
    if ($Credential) { $userName = [string]$Credential.UserName }
    $memKey = '{0}|{1}' -f $ComputerName.ToLowerInvariant(), $userName.ToLowerInvariant()

    $effective = $Protocol
    if ($Protocol -eq 'Auto' -and $script:NodeProtocol.ContainsKey($memKey)) {
        $effective = $script:NodeProtocol[$memKey]
    }

    $cacheKey = Get-WmicSessionCacheKey $ComputerName $userName $effective
    $cached = Get-WmicCachedSession $cacheKey
    if ($cached) { return $cached }

    $base = @{
        ComputerName = $ComputerName
        ErrorAction  = 'Stop'
    }
    if ($Credential) { $base.Credential = $Credential }

    $wsmanErr = $null
    $session = $null
    $used = $effective

    switch ($effective) {
        'Dcom' {
            $session = New-CimSession @base -SessionOption (New-WmicDcomSessionOption)
            $used = 'Dcom'
        }
        'Wsman' {
            $session = New-CimSession @base -OperationTimeoutSec 5
            $used = 'Wsman'
        }
        default {
            try {
                $session = New-CimSession @base -OperationTimeoutSec 5
                $used = 'Wsman'
            }
            catch {
                if (-not (Test-WmicWsmanFailure $_)) { throw }
                $wsmanErr = $_
                $session = $null
            }
            if ($null -eq $session) {
                try {
                    $session = New-CimSession @base -SessionOption (New-WmicDcomSessionOption)
                    $used = 'Dcom'
                }
                catch {
                    $dcomMsg = $_.Exception.Message
                    $wsMsg = $wsmanErr.Exception.Message
                    throw ("/NODE:{0} : WS-Man 失敗 ({1}); DCOM も失敗 ({2})" -f $ComputerName, $wsMsg, $dcomMsg)
                }
                Write-Verbose ("/NODE:{0} : WS-Man 不可のため DCOM にフォールバック" -f $ComputerName)
                if (-not $script:DcomWarned.ContainsKey($memKey)) {
                    Write-Warning ("/NODE:{0} : WS-Man に失敗したため DCOM で接続しました。固定するなら /protocol:dcom" -f $ComputerName)
                    $script:DcomWarned[$memKey] = $true
                }
            }
        }
    }

    $script:NodeProtocol[$memKey] = $used
    $finalKey = Get-WmicSessionCacheKey $ComputerName $userName $used
    $script:CimSessionCache[$finalKey] = @{ Session = $session; Protocol = $used }
    return $session
}

function Resolve-WmicCimTargets {
    param($Parsed)
    $nodes = @(Get-WmicNodeList $Parsed)
    $cred = Get-WmicCredential $Parsed
    $proto = Resolve-WmicProtocol $Parsed

    if ($nodes.Count -eq 0) {
        if ($cred) {
            Write-Warning '/USER は /NODE 付きのリモート セッションにだけ使います。'
        }
        return @{ Sessions = @(); AlsoLocal = $true }
    }

    $sessions = New-Object System.Collections.Generic.List[object]
    $alsoLocal = $false
    foreach ($n in $nodes) {
        if (Test-WmicLocalNode $n) {
            $alsoLocal = $true
            continue
        }
        $s = Connect-WmicCimSession -ComputerName $n -Credential $cred -Protocol $proto
        if ($s) { [void]$sessions.Add($s) }
    }
    return @{ Sessions = @($sessions); AlsoLocal = $alsoLocal }
}

function Get-WmicCimParamSets {
    param([hashtable]$Query, $Targets)
    $sets = New-Object System.Collections.Generic.List[hashtable]
    if ($Targets.AlsoLocal) {
        $sets.Add($Query)
    }
    if ($Targets.Sessions -and @($Targets.Sessions).Count -gt 0) {
        $q = @{}
        foreach ($k in $Query.Keys) { $q[$k] = $Query[$k] }
        $q['CimSession'] = @($Targets.Sessions)
        $sets.Add($q)
    }
    if ($sets.Count -eq 0) {
        throw '/NODE の対象が空です。'
    }
    return @($sets)
}

function Close-WmicCimSessions {
    foreach ($entry in @($script:CimSessionCache.Values)) {
        $session = $null
        if ($entry -is [hashtable] -and $entry.ContainsKey('Session')) { $session = $entry.Session }
        else { $session = $entry }
        if ($null -eq $session) { continue }
        try { Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue } catch { }
    }
    $script:CimSessionCache = @{}
}

function ConvertTo-WmicValue {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [bool]) { if ($Value) { return 'TRUE' } else { return 'FALSE' } }
    if ($Value -is [System.Array]) {
        $inner = @($Value | ForEach-Object {
            if ($_ -is [string]) { '"{0}"' -f $_ } else { ConvertTo-WmicValue $_ }
        }) -join ', '
        return '{' + $inner + '}'
    }
    if ($Value -is [datetime]) { return $Value.ToString('yyyyMMddHHmmss.ffffffzzz') }
    return [string]$Value
}

function Resolve-WmicPropertyCase {
    param($Names, $Objects)
    $list = ConvertTo-WmicList $Names
    if ($list.Count -eq 0) { return , $list }
    $sample = $null
    foreach ($o in (ConvertTo-WmicList $Objects)) { $sample = $o; break }
    if ($null -eq $sample) { return , $list }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($n in $list) {
        $key = [string]$n
        $exact = $sample.PSObject.Properties[$key]
        if ($exact) { $out.Add($exact.Name); continue }
        $hit = $sample.PSObject.Properties | Where-Object { $_.Name -ieq $key } | Select-Object -First 1
        if ($hit) { $out.Add($hit.Name) } else { $out.Add($key) }
    }
    return , $out
}

function Format-WmicTable {
    param($Objects, $Properties)
    $rows = ConvertTo-WmicList $Objects
    if ($rows.Count -eq 0) { return }
    $Properties = ConvertTo-WmicList $Properties
    if ($Properties.Count -eq 0) {
        $Properties = ConvertTo-WmicList @($rows[0].PSObject.Properties | Where-Object { $_.Name -notmatch '^Cim' } | Select-Object -ExpandProperty Name)
    }
    $stringRows = New-Object System.Collections.Generic.List[object]
    foreach ($row in $rows) {
        $cells = New-Object System.Collections.Generic.List[string]
        foreach ($c in $Properties) {
            $cells.Add((ConvertTo-WmicValue $row.$c))
        }
        $stringRows.Add($cells)
    }
    $widths = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $Properties.Count; $i++) {
        $w = ([string]$Properties[$i]).Length
        foreach ($r in $stringRows) {
            if ($r[$i].Length -gt $w) { $w = $r[$i].Length }
        }
        $widths.Add($w)
    }
    $header = for ($i = 0; $i -lt $Properties.Count; $i++) { ([string]$Properties[$i]).PadRight($widths[$i]) }
    Write-Output ($header -join '  ')
    foreach ($r in $stringRows) {
        $line = for ($i = 0; $i -lt $Properties.Count; $i++) { $r[$i].PadRight($widths[$i]) }
        Write-Output ($line -join '  ')
    }
}

function Format-WmicList {
    param($Objects, $Properties)
    $rows = ConvertTo-WmicList $Objects
    $first = $true
    foreach ($row in $rows) {
        if (-not $first) { Write-Output '' }
        $first = $false
        $props = ConvertTo-WmicList $Properties
        if ($props.Count -eq 0) {
            $props = ConvertTo-WmicList @($row.PSObject.Properties | Where-Object { $_.Name -notmatch '^Cim' } | Select-Object -ExpandProperty Name)
        }
        $keyWidth = 0
        foreach ($c in $props) {
            $n = ([string]$c).Length
            if ($n -gt $keyWidth) { $keyWidth = $n }
        }
        foreach ($c in $props) {
            Write-Output ('{0}={1}' -f ([string]$c).PadRight($keyWidth), (ConvertTo-WmicValue $row.$c))
        }
    }
}

function Write-WmicFormatted {
    param($Parsed, $Objects, $Properties)
    $fmt = Resolve-WmicFormat $Parsed
    switch ($fmt) {
        'CSV' {
            $rows = ConvertTo-WmicList $Objects
            $propNames = ConvertTo-WmicList $Properties
            if ($propNames.Count -gt 0) { $rows | Select-Object -Property ([string[]]$propNames.ToArray()) | ConvertTo-Csv -NoTypeInformation }
            else { $rows | ConvertTo-Csv -NoTypeInformation }
        }
        'XML' {
            $rows = ConvertTo-WmicList $Objects
            $propNames = ConvertTo-WmicList $Properties
            if ($propNames.Count -gt 0) { $rows | Select-Object -Property ([string[]]$propNames.ToArray()) | ConvertTo-Xml -As String }
            else { $rows | ConvertTo-Xml -As String }
        }
        'LIST' { Format-WmicList $Objects $Properties }
        'VALUE' { Format-WmicList $Objects $Properties }
        default { Format-WmicTable $Objects $Properties }
    }
}

function Get-CimMethodMap {
    param([string]$ClassName, [string]$MethodName, [string]$Namespace, $Targets)
    $gc = @{ ClassName = $ClassName }
    if ($Namespace) { $gc.Namespace = $Namespace }
    foreach ($p in Get-WmicCimParamSets $gc $Targets) {
        try {
            $cls = Get-CimClass @p
            $m = $cls.CimClassMethods | Where-Object { $_.Name -eq $MethodName }
            if (-not $m) { $m = $cls.CimClassMethods | Where-Object { $_.Name -ieq $MethodName } }
            if ($m) { return @($m)[0] }
        }
        catch { }
    }
    return $null
}

function ConvertTo-MethodArguments {
    param($MethodMeta, [string[]]$CallArgs, $Info)
    $hash = @{}
    if ((Get-WmicLen $CallArgs) -eq 0) { return $hash }
    $names = @()
    if ($MethodMeta) {
        foreach ($p in $MethodMeta.Parameters) {
            $qual = @($p.Qualifiers | ForEach-Object { $_.Name })
            if ($qual -contains 'In' -or $qual -contains 'IN') { $names += $p.Name }
        }
    }
    elseif ($Info -and $Info.methods) {
        $listed = @($Info.methods | Where-Object { $_.name -ieq $MethodMeta })
        # fallback handled below
    }
    if ($names.Count -eq 0 -and $Info -and $Info.methods -and $CallArgs) {
        # caller may pass method name separately; handled in Invoke
    }
    $argArr = @(ConvertTo-WmicList $CallArgs)
    for ($i = 0; $i -lt $argArr.Count; $i++) {
        if ($i -lt $names.Count) { $hash[$names[$i]] = $argArr[$i] }
        else { $hash["Arg$i"] = $argArr[$i] }
    }
    return $hash
}

function Write-WmicHelp {
    param($Parsed, $Info)
    if ($Info) {
        $aliasName = $Info.className
        if ($Parsed.Alias) { $aliasName = $Parsed.Alias.ToUpperInvariant() }
        $ns = Get-NoteProperty $Info 'namespace'
        if (-not $ns) { $ns = $script:DefaultNamespace }
        Write-Output ('{0}  →  {1}  ({2})' -f $aliasName, $Info.className, $ns)
        $caution = Get-NoteProperty $Info 'caution'
        if ($caution) { Write-Output ('注意: {0}' -f $caution) }
        $brief = Get-NoteProperty $Info 'brief'
        if ($brief) { Write-Output ('LIST BRIEF: {0}' -f ((ConvertTo-WmicList $brief) -join ', ')) }
        $methods = Get-NoteProperty $Info 'methods'
        if ($methods) {
            $bits = New-Object System.Collections.Generic.List[string]
            foreach ($m in (ConvertTo-WmicList $methods)) {
                $mn = Get-NoteProperty $m 'name'
                if ($mn) { $bits.Add($mn) }
            }
            if ($bits.Count -gt 0) { Write-Output ('CALL: {0}' -f ($bits -join ', ')) }
        }
        $ex = 'PATH ' + $Info.className
        if ($Parsed.Alias) { $ex = $Parsed.Alias.ToLowerInvariant() }
        Write-Output ('例: wmic {0} list brief' -f $ex)
        Write-Output '仕様は SPEC.md。エイリアス定義は aliases.json。'
        return
    }
    $path = Join-Path $PSScriptRoot 'HELP.txt'
    if (Test-Path -LiteralPath $path) {
        $utf8 = New-Object System.Text.UTF8Encoding $true
        $text = [System.IO.File]::ReadAllText($path, $utf8)
        if ($text.Length -gt 0 -and [int][char]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }
        Write-Output $text.TrimEnd()
        return
    }
    Write-Output 'CIMIC. 同じフォルダの SPEC.md を見てください。'
}

function Invoke-WmicParsed {
    param($Parsed)

    if ($Parsed.Help -or (-not $Parsed.Alias -and -not $Parsed.PathClass)) {
        $info = $null
        if ($Parsed.Alias) { $info = Get-WmicAliasInfo $Parsed.Alias }
        Write-WmicHelp $Parsed $info
        return
    }

    $target = Resolve-WmicTarget $Parsed
    $info = $target.Info
    $className = $target.ClassName
    $ns = $target.Namespace

    if ($Parsed.Alias -and $Parsed.Alias.ToUpperInvariant() -eq 'ALIAS') {
        $doc = Get-WmicAliasDocument
        $rows = foreach ($p in $doc.PSObject.Properties) {
            [pscustomobject]@{
                FriendlyName = $p.Name
                Target       = $p.Value.className
            }
        }
        $props = Get-WmicSelectProperties $Parsed $info
        if (-not $props) { $props = @('FriendlyName', 'Target') }
        Write-WmicFormatted $Parsed $rows $props
        return
    }

    if ($info -and $info.caution) {
        Write-Warning $info.caution
    }

    $dangerous = @('CIM_DataFile', 'Win32_Directory', 'Win32_NTLogEvent')
    if ($dangerous -contains $className -and -not $Parsed.Where) {
        throw "$className は WHERE 無しでは実行しません。Name / Logfile などで絞ってください。"
    }

    $verb = $Parsed.Verb
    if (-not $verb) { $verb = 'GET' }
    $query = New-WmicQueryParams $Parsed $className $ns
    $targets = Resolve-WmicCimTargets $Parsed
    $paramSets = @(Get-WmicCimParamSets $query $targets)

    switch ($verb) {
        { $_ -eq 'GET' -or $_ -eq 'LIST' } {
            $objects = foreach ($p in $paramSets) { Get-CimInstance @p }
            $props = Get-WmicSelectProperties $Parsed $info
            if ((Get-WmicLen $props) -gt 0) {
                $props = Resolve-WmicPropertyCase $props $objects
                $propNames = New-Object string[] $props.Count
                for ($i = 0; $i -lt $props.Count; $i++) { $propNames[$i] = [string]$props[$i] }
                $objects = $objects | Select-Object -Property $propNames
            }
            Write-WmicFormatted $Parsed $objects $props
        }
        'DELETE' {
            if (-not $query.ContainsKey('Filter')) {
                throw 'WHERE の無い DELETE は拒否します。'
            }
            foreach ($p in $paramSets) { Get-CimInstance @p | Remove-CimInstance }
        }
        'SET' {
            if ((Get-WmicLen $Parsed.SetPairs) -eq 0) { throw 'SET には name=value が必要です。' }
            $hash = @{}
            foreach ($pair in $Parsed.SetPairs) { $hash[$pair.Name] = $pair.Value }
            foreach ($p in $paramSets) { Get-CimInstance @p | Set-CimInstance -Property $hash }
        }
        'CREATE' {
            if ((Get-WmicLen $Parsed.CreatePairs) -eq 0) { throw 'CREATE には name=value が必要です。' }
            $hash = @{}
            foreach ($pair in $Parsed.CreatePairs) { $hash[$pair.Name] = $pair.Value }
            foreach ($p in $paramSets) {
                $np = @{ ClassName = $className; Property = $hash }
                if ($p.ContainsKey('Namespace')) { $np.Namespace = $p.Namespace }
                if ($p.ContainsKey('CimSession')) { $np.CimSession = $p.CimSession }
                New-CimInstance @np
            }
        }
        'CALL' {
            if (-not $Parsed.CallMethod) {
                $info2 = $info
                Write-WmicHelp $Parsed $info2
                return
            }
            $meta = Get-CimMethodMap $className $Parsed.CallMethod $ns $targets
            $methodName = $Parsed.CallMethod
            if ($meta) { $methodName = $meta.Name }
            elseif ($info -and (Get-NoteProperty $info 'methods')) {
                $hit = @((Get-NoteProperty $info 'methods') | Where-Object { $_.name -ieq $Parsed.CallMethod })
                if ($hit.Count -gt 0) { $methodName = $hit[0].name }
            }
            $argHash = @{}
            if ($meta) {
                $argHash = ConvertTo-MethodArguments $meta $Parsed.CallArgs $info
            }
            elseif ($info -and $info.methods) {
                $hit = @($info.methods | Where-Object { $_.name -ieq $methodName })
                if ($hit.Count -gt 0 -and $hit[0].inParams) {
                    $names = @($hit[0].inParams | ForEach-Object { $_.name })
                    $callArgs = @(ConvertTo-WmicList $Parsed.CallArgs)
                    for ($i = 0; $i -lt $callArgs.Count; $i++) {
                        if ($i -lt $names.Count) { $argHash[$names[$i]] = $callArgs[$i] }
                    }
                }
            }
            $isStatic = $false
            if ($meta -and $meta.Qualifiers) {
                $qnames = @($meta.Qualifiers | ForEach-Object { $_.Name })
                if ($qnames -contains 'Static') { $isStatic = $true }
            }
            if ($methodName -ieq 'Create') { $isStatic = $true }

            if ($isStatic -or -not $query.ContainsKey('Filter')) {
                foreach ($p in $paramSets) {
                    $im = @{ ClassName = $className; MethodName = $methodName }
                    if ($p.ContainsKey('Namespace')) { $im.Namespace = $p.Namespace }
                    if ($p.ContainsKey('CimSession')) { $im.CimSession = $p.CimSession }
                    if ($argHash.Count -gt 0) { $im.Arguments = $argHash }
                    Invoke-CimMethod @im
                }
            }
            else {
                foreach ($p in $paramSets) {
                    $inst = Get-CimInstance @p
                    $im = @{ MethodName = $methodName }
                    if ($argHash.Count -gt 0) { $im.Arguments = $argHash }
                    $inst | Invoke-CimMethod @im
                }
            }
        }
        'ASSOCIATORS' {
            foreach ($p in $paramSets) {
                Get-CimInstance @p | Get-CimAssociatedInstance
            }
        }
        default { throw "未対応の動詞です: $verb" }
    }
}

function Invoke-WmicLine {
    param([string]$Line)
    $trim = $Line.Trim()
    if (-not $trim) { return }
    if ($trim -match '^(quit|exit|q)$') { return 'EXIT' }
    $parsed = Parse-WmicLine $trim
    $outputPath = Get-WmicSwitchValue $parsed 'output'
    $appendPath = Get-WmicSwitchValue $parsed 'append'
    if ($outputPath -is [string] -and $outputPath) {
        $text = Invoke-WmicParsed $parsed | Out-String
        Set-Content -LiteralPath $outputPath -Value $text -Encoding UTF8
        return
    }
    if ($appendPath -is [string] -and $appendPath) {
        $text = Invoke-WmicParsed $parsed | Out-String
        Add-Content -LiteralPath $appendPath -Value $text -Encoding UTF8
        return
    }
    Invoke-WmicParsed $parsed
}

function Start-WmicInteractive {
    Write-Host 'CIMIC — WMIC compatibility wrapper.  quit で終了。' -ForegroundColor DarkGray
    $script:KeepCimSessions = $true
    $ns = $script:DefaultNamespace
    try {
        while ($true) {
            $prompt = "wmic:$($ns -replace '/','\')>"
            try { $line = Read-Host $prompt }
            catch { break }
            if ($null -eq $line) { break }
            try {
                $r = Invoke-WmicLine $line
                if ($r -eq 'EXIT') { break }
            }
            catch {
                Write-Error $_
            }
        }
    }
    finally {
        $script:KeepCimSessions = $false
        Close-WmicCimSessions
    }
}

# --- entry ---
try {
    [void](Get-WmicAliasDocument)
}
catch {
    Write-Error $_
    exit 1
}

if ($WmicArgs -is [string]) {
    if ([string]::IsNullOrWhiteSpace($WmicArgs)) { $argList = @() }
    else { $argList = @([string]$WmicArgs) }
}
elseif ($null -eq $WmicArgs) {
    $argList = @()
}
else {
    $argList = @($WmicArgs | ForEach-Object { $_ } | Where-Object { $_ -ne $null -and "$_" -ne '' })
}

if ((Get-WmicLen $argList) -eq 0) {
    Start-WmicInteractive
    exit 0
}

$joined = ($argList -join ' ')
try {
    Invoke-WmicLine $joined
}
catch {
    Write-Error $_
    exit 1
}
finally {
    Close-WmicCimSessions
}
