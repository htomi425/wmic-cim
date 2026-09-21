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
  Spec:    SPEC.md  ( /NODE プロトコル、拒否条件、出力の契約 )
#>
[CmdletBinding()]
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
    if ([string]::IsNullOrWhiteSpace($Line)) { return $tokens }
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
    return ,$tokens.ToArray()
}

function ConvertTo-WqlFilter {
    param([string]$Where)
    if ([string]::IsNullOrWhiteSpace($Where)) { return $null }
    $s = $Where.Trim()
    if ($s.StartsWith('(') -and $s.EndsWith(')')) {
        $s = $s.Substring(1, $s.Length - 2).Trim()
    }
    $s = [regex]::Replace($s, '"([^"]*)"', { param($m) "'" + ($m.Groups[1].Value.Replace("'", "''")) + "'" })
    $s = [regex]::Replace($s, '\s*==\s*', '=')
    return $s
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
    return ,$out.ToArray()
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
    $tokens = @(Get-WmicTokens $Line)
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
        $restArr = $rest.ToArray()
        switch ($parsed.Verb) {
            'GET' { $parsed.Properties = @(Split-WmicCsv $restArr) }
            'LIST' {
                if ($restArr.Count -gt 0) {
                    $parsed.ListStyle = $restArr[0].ToUpperInvariant()
                    if ($restArr.Count -gt 1) { $parsed.Properties = @(Split-WmicCsv $restArr[1..($restArr.Count - 1)]) }
                }
                else { $parsed.ListStyle = 'FULL' }
            }
            'SET' { $parsed.SetPairs = @(Parse-WmicPairs $restArr) }
            'CREATE' { $parsed.CreatePairs = @(Parse-WmicPairs $restArr) }
            'CALL' {
                if ($restArr.Count -gt 0) {
                    $parsed.CallMethod = $restArr[0]
                    if ($restArr.Count -gt 1) { $parsed.CallArgs = @(Split-WmicCsv $restArr[1..($restArr.Count - 1)]) }
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
    if ($Parsed.Properties -and $Parsed.Properties.Count -gt 0) { return @($Parsed.Properties) }
    if ($Parsed.Verb -eq 'LIST' -and $Parsed.ListStyle -eq 'BRIEF' -and $Info) {
        return @($Info.brief)
    }
    if ($Parsed.Verb -eq 'LIST' -and ($Parsed.ListStyle -eq 'FULL' -or -not $Parsed.ListStyle)) {
        return $null
    }
    if ($Info -and $Info.defaultGet) { return @($Info.defaultGet) }
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

function Format-WmicTable {
    param($Objects, [string[]]$Properties)
    $rows = @($Objects)
    if ($rows.Count -eq 0) { return }
    if (-not $Properties) {
        $Properties = @($rows[0].PSObject.Properties | Where-Object { $_.Name -notmatch '^Cim' } | Select-Object -ExpandProperty Name)
    }
    $stringRows = @()
    foreach ($row in $rows) {
        $cells = @()
        foreach ($c in $Properties) {
            $cells += (ConvertTo-WmicValue $row.$c)
        }
        $stringRows += ,$cells
    }
    $widths = @()
    for ($i = 0; $i -lt $Properties.Count; $i++) {
        $w = $Properties[$i].Length
        foreach ($r in $stringRows) {
            if ($r[$i].Length -gt $w) { $w = $r[$i].Length }
        }
        $widths += $w
    }
    $header = for ($i = 0; $i -lt $Properties.Count; $i++) { $Properties[$i].PadRight($widths[$i]) }
    Write-Output ($header -join '  ')
    foreach ($r in $stringRows) {
        $line = for ($i = 0; $i -lt $Properties.Count; $i++) { $r[$i].PadRight($widths[$i]) }
        Write-Output ($line -join '  ')
    }
}

function Format-WmicList {
    param($Objects, [string[]]$Properties)
    $rows = @($Objects)
    $first = $true
    foreach ($row in $rows) {
        if (-not $first) { Write-Output '' }
        $first = $false
        $props = $Properties
        if (-not $props) {
            $props = @($row.PSObject.Properties | Where-Object { $_.Name -notmatch '^Cim' } | Select-Object -ExpandProperty Name)
        }
        $keyWidth = ($props | Measure-Object -Maximum -Property Length).Maximum
        foreach ($c in $props) {
            Write-Output ('{0}={1}' -f $c.PadRight($keyWidth), (ConvertTo-WmicValue $row.$c))
        }
    }
}

function Write-WmicFormatted {
    param($Parsed, $Objects, [string[]]$Properties)
    $fmt = Resolve-WmicFormat $Parsed
    $rows = @($Objects)
    switch ($fmt) {
        'CSV' {
            if ($Properties) { $rows | Select-Object $Properties | ConvertTo-Csv -NoTypeInformation }
            else { $rows | ConvertTo-Csv -NoTypeInformation }
        }
        'XML' {
            if ($Properties) { $rows | Select-Object $Properties | ConvertTo-Xml -As String }
            else { $rows | ConvertTo-Xml -As String }
        }
        'LIST' { Format-WmicList $rows $Properties }
        'VALUE' { Format-WmicList $rows $Properties }
        default { Format-WmicTable $rows $Properties }
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
    if (-not $CallArgs -or $CallArgs.Count -eq 0) { return $hash }
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
    for ($i = 0; $i -lt $CallArgs.Count; $i++) {
        if ($i -lt $names.Count) { $hash[$names[$i]] = $CallArgs[$i] }
        else { $hash["Arg$i"] = $CallArgs[$i] }
    }
    return $hash
}

function Write-WmicHelp {
    param($Parsed, $Info)
    if ($Info) {
        Write-Output ("{0}  ->  {1}" -f $(if ($Parsed.Alias) { $Parsed.Alias.ToUpperInvariant() } else { $Info.className }), $Info.className)
        if ($Info.brief) { Write-Output ("BRIEF: {0}" -f ($Info.brief -join ', ')) }
        if ($Info.defaultGet) { Write-Output ("GET:   {0}" -f ($Info.defaultGet -join ', ')) }
        if ($Info.methods) {
            Write-Output 'METHODS:'
            foreach ($m in @($Info.methods)) {
                $args = @($m.inParams | ForEach-Object { $_.name }) -join ', '
                Write-Output ("  {0}({1})  {2}" -f $m.name, $args, $m.description)
            }
        }
        return
    }
    Write-Output @'
CIMIC — WMIC compatibility wrapper (CIM)

Usage:
  wmic [switches] <alias | PATH class> [where <expr>] <verb> [args]

Switches:
  /NODE:host[,host2]     リモート。既定は WS-Man、接続失敗時だけ DCOM
  /PROTOCOL:AUTO|WSMAN|DCOM
                         /NODE のプロトコル（CIMIC 拡張。環境変数 WMIC_PROTOCOL でも可）
  /NAMESPACE:root\cimv2  Namespace
  /USER:name             Credential（/NODE と一緒に使う）
  /PASSWORD:secret       (plain; prefer /USER alone for a prompt)
  /FORMAT:TABLE|LIST|CSV|VALUE|XML
  /OUTPUT:file           Write stdout to file
  /APPEND:file           Append stdout to file

Verbs:
  GET [prop[,prop...]]
  LIST [BRIEF|FULL]
  SET name=value[,...]
  CALL method [args]
  CREATE name=value[,...]
  DELETE
  ASSOCIATORS

Examples:
  wmic os get caption,version,buildnumber
  wmic process where name="explorer.exe" get processid,workingsetsize
  wmic service where startmode="auto" get name,state
  wmic path Win32_Process where processid=4 get name
  wmic process call create "notepad.exe"
  wmic /node:HOST os get caption
  wmic /protocol:dcom /node:HOST os get caption
'@
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
            if ($props) { $objects = $objects | Select-Object $props }
            Write-WmicFormatted $Parsed $objects $props
        }
        'DELETE' {
            if (-not $query.ContainsKey('Filter')) {
                throw 'WHERE の無い DELETE は拒否します。'
            }
            foreach ($p in $paramSets) { Get-CimInstance @p | Remove-CimInstance }
        }
        'SET' {
            if (-not $Parsed.SetPairs -or $Parsed.SetPairs.Count -eq 0) { throw 'SET には name=value が必要です。' }
            $hash = @{}
            foreach ($pair in $Parsed.SetPairs) { $hash[$pair.Name] = $pair.Value }
            foreach ($p in $paramSets) { Get-CimInstance @p | Set-CimInstance -Property $hash }
        }
        'CREATE' {
            if (-not $Parsed.CreatePairs -or $Parsed.CreatePairs.Count -eq 0) { throw 'CREATE には name=value が必要です。' }
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
                    for ($i = 0; $i -lt $Parsed.CallArgs.Count; $i++) {
                        if ($i -lt $names.Count) { $argHash[$names[$i]] = $Parsed.CallArgs[$i] }
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

if (-not $WmicArgs -or $WmicArgs.Count -eq 0) {
    Start-WmicInteractive
    exit 0
}

$joined = ($WmicArgs -join ' ')
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
