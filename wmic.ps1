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
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
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

function New-WmicCimParams {
    param($Parsed, [string]$ClassName, [string]$Namespace)
    $p = @{ ClassName = $ClassName }
    if ($Namespace -and $Namespace -ne 'root/cimv2') { $p.Namespace = $Namespace }
    $node = Get-WmicSwitchValue $Parsed 'node'
    if ($node -is [string] -and $node) {
        $nodes = @($node -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($nodes.Count -eq 1) { $p.ComputerName = $nodes[0] }
        elseif ($nodes.Count -gt 1) { $p.ComputerName = $nodes }
    }
    $user = Get-WmicSwitchValue $Parsed 'user'
    $pass = Get-WmicSwitchValue $Parsed 'password'
    if ($user -or $pass) {
        if ($pass -is [string] -and $pass) {
            $sec = ConvertTo-SecureString $pass -AsPlainText -Force
            $p.Credential = New-Object System.Management.Automation.PSCredential (($user).ToString(), $sec)
        }
        else {
            $p.Credential = Get-Credential -UserName $user
        }
    }
    $filter = ConvertTo-WqlFilter $Parsed.Where
    if ($filter) { $p.Filter = $filter }
    return $p
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
    param([string]$ClassName, [string]$MethodName, [string]$Namespace, $SessionParams)
    try {
        $gc = @{ ClassName = $ClassName }
        if ($Namespace) { $gc.Namespace = $Namespace }
        if ($SessionParams.ContainsKey('ComputerName')) { $gc.ComputerName = $SessionParams.ComputerName }
        if ($SessionParams.ContainsKey('Credential')) { $gc.Credential = $SessionParams.Credential }
        $cls = Get-CimClass @gc
        $m = $cls.CimClassMethods | Where-Object { $_.Name -eq $MethodName }
        if (-not $m) { $m = $cls.CimClassMethods | Where-Object { $_.Name -ieq $MethodName } }
        return $m
    }
    catch { return $null }
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
  /NODE:host[,host2]     ComputerName
  /NAMESPACE:root\cimv2  Namespace
  /USER:name             Credential
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
    $cimParams = New-WmicCimParams $Parsed $className $ns

    switch ($verb) {
        { $_ -eq 'GET' -or $_ -eq 'LIST' } {
            $objects = Get-CimInstance @cimParams
            $props = Get-WmicSelectProperties $Parsed $info
            if ($props) { $objects = $objects | Select-Object $props }
            Write-WmicFormatted $Parsed $objects $props
        }
        'DELETE' {
            if (-not $cimParams.ContainsKey('Filter')) {
                throw 'WHERE の無い DELETE は拒否します。'
            }
            Get-CimInstance @cimParams | Remove-CimInstance
        }
        'SET' {
            if (-not $Parsed.SetPairs -or $Parsed.SetPairs.Count -eq 0) { throw 'SET には name=value が必要です。' }
            $hash = @{}
            foreach ($pair in $Parsed.SetPairs) { $hash[$pair.Name] = $pair.Value }
            Get-CimInstance @cimParams | Set-CimInstance -Property $hash
        }
        'CREATE' {
            if (-not $Parsed.CreatePairs -or $Parsed.CreatePairs.Count -eq 0) { throw 'CREATE には name=value が必要です。' }
            $hash = @{}
            foreach ($pair in $Parsed.CreatePairs) { $hash[$pair.Name] = $pair.Value }
            $np = @{ ClassName = $className; Property = $hash }
            if ($cimParams.ContainsKey('Namespace')) { $np.Namespace = $cimParams.Namespace }
            if ($cimParams.ContainsKey('ComputerName')) { $np.ComputerName = $cimParams.ComputerName }
            if ($cimParams.ContainsKey('Credential')) { $np.Credential = $cimParams.Credential }
            New-CimInstance @np
        }
        'CALL' {
            if (-not $Parsed.CallMethod) {
                $info2 = $info
                Write-WmicHelp $Parsed $info2
                return
            }
            $sessionBits = @{}
            if ($cimParams.ContainsKey('ComputerName')) { $sessionBits.ComputerName = $cimParams.ComputerName }
            if ($cimParams.ContainsKey('Credential')) { $sessionBits.Credential = $cimParams.Credential }
            $meta = Get-CimMethodMap $className $Parsed.CallMethod $ns $sessionBits
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

            if ($isStatic -or -not $cimParams.ContainsKey('Filter')) {
                $im = @{ ClassName = $className; MethodName = $methodName }
                if ($ns -and $ns -ne 'root/cimv2') { $im.Namespace = $ns }
                if ($sessionBits.ContainsKey('ComputerName')) { $im.ComputerName = $sessionBits.ComputerName }
                if ($sessionBits.ContainsKey('Credential')) { $im.Credential = $sessionBits.Credential }
                if ($argHash.Count -gt 0) { $im.Arguments = $argHash }
                Invoke-CimMethod @im
            }
            else {
                $inst = Get-CimInstance @cimParams
                $im = @{ MethodName = $methodName }
                if ($argHash.Count -gt 0) { $im.Arguments = $argHash }
                $inst | Invoke-CimMethod @im
            }
        }
        'ASSOCIATORS' {
            Get-CimInstance @cimParams | Get-CimAssociatedInstance
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
    $ns = $script:DefaultNamespace
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
