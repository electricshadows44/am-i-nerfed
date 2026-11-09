# am-i-nerfed (Windows): detect, explain and opt out of Claude Code server-side
# experiment assignments (the x-cc-atis request header).
#
# PowerShell port of am-i-nerfed.sh for native Windows: same commands, output
# and exit codes, no jq needed. Requires PowerShell 7.2+ (pwsh), whose
# System.Text.Json rewrites the config without touching anything else.
#
#   check (default)  table of cached experiment slots + a verdict per model
#   history          experiment IDs recorded in local session transcripts
#   optout           back up the config, delete data.atis / data.experimentKey
#   restore          put back the newest optout backup
#   statusline       print a ready-to-paste status line snippet
#
# Unofficial. Reads undocumented Claude Code internals and may break on any
# Claude Code release. Makes no network calls. Never prints account or OAuth
# values; prints whole assignment tokens only when asked to with --full.
#
# The file must stay parseable by Windows PowerShell 5.1 (no ??, ?:, && or ||),
# so that 5.1 reaches the version check below instead of a parse error.
#                                                   SPDX-License-Identifier: MIT

$AMN_VERSION = '0.1.2'
$ENV_VAR = 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC'
$PROG = 'am-i-nerfed.ps1'

$v = $PSVersionTable.PSVersion
if ($v.Major -lt 7 -or ($v.Major -eq 7 -and $v.Minor -lt 2)) {
  [Console]::Error.WriteLine("am-i-nerfed: PowerShell 7.2 or newer is required; this is $v.")
  [Console]::Error.WriteLine('  Install it with:  winget install Microsoft.PowerShell')
  [Console]::Error.WriteLine("  then run:         pwsh -File $PROG check")
  exit 2
}

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
trap { [Console]::Error.WriteLine("am-i-nerfed: internal error: $_"); CleanTmp; exit 2 }

$ScriptArgs = @($args)
$Inv = [Globalization.CultureInfo]::InvariantCulture
$DocOpts = [System.Text.Json.JsonDocumentOptions]::new()
$DocOpts.MaxDepth = 1024

# ----------------------------------------------------------------- helpers --

function Say([string]$s = '') { Write-Output $s }
function Warn([string]$s) { [Console]::Error.WriteLine("am-i-nerfed: $s") }
function Die([string]$s) { Warn $s; CleanTmp; exit 2 }
function DieUsage([string]$s) { Warn $s; [Console]::Error.WriteLine("Run `"$PROG --help`" for usage."); exit 2 }

# Mirrors Claude Code (Node's os.homedir): USERPROFILE on Windows.
$UserHome = $env:USERPROFILE
if (-not $UserHome) { $UserHome = $env:HOME }
if (-not $UserHome) { $UserHome = $HOME }

# Show paths under the home directory as ~\... (display only).
function Tildify([string]$p) {
  $h = $UserHome.TrimEnd('\', '/')
  if (-not $h) { return $p }
  if ($p.Equals($h, [StringComparison]::OrdinalIgnoreCase)) { return '~' }
  if ($p.Length -gt $h.Length -and $p.StartsWith($h, [StringComparison]::OrdinalIgnoreCase) -and '\/'.Contains($p[$h.Length])) {
    return '~' + $p.Substring($h.Length)
  }
  return $p
}

function IsNum($x) { return ($x -is [long] -or $x -is [int] -or $x -is [double] -or $x -is [decimal]) }
function IsObj($x) { return ($x -is [System.Collections.IDictionary]) }
function IsArr($x) { return ($x -is [object[]]) }
function NonEmptyStr($x) { if ($x -is [string] -and $x.Length -gt 0) { return $x }; return $null }
function Coalesce($a, $b) { if ($null -eq $a -or ($a -is [bool] -and -not $a)) { return $b }; return $a }

# jq's tostring: strings as they are, everything else as compact JSON.
function ToJqString($x) {
  if ($x -is [string]) { return $x }
  if ($null -eq $x) { return 'null' }
  if ($x -is [bool]) { if ($x) { return 'true' }; return 'false' }
  if ($x -is [long] -or $x -is [int]) { return $x.ToString($Inv) }
  if (IsNum $x) { return ([double]$x).ToString('R', $Inv) }
  return (ConvertTo-Json -InputObject $x -Compress -Depth 100)
}

# JsonElement -> ordered dictionaries, arrays, strings, long/double, bool, null.
function FromJE([System.Text.Json.JsonElement]$e) {
  switch ($e.ValueKind.ToString()) {
    'Object' {
      $h = [ordered]@{}
      foreach ($p in $e.EnumerateObject()) { $h[$p.Name] = FromJE $p.Value }
      return , $h
    }
    'Array' {
      $l = [System.Collections.Generic.List[object]]::new()
      foreach ($x in $e.EnumerateArray()) { $l.Add((FromJE $x)) }
      return , $l.ToArray()
    }
    'String' { return $e.GetString() }
    'Number' { $i = 0L; if ($e.TryGetInt64([ref]$i)) { return $i }; return $e.GetDouble() }
    'True' { return $true }
    'False' { return $false }
    default { return $null }
  }
}

function ParseJson([string]$text) { return [System.Text.Json.JsonDocument]::Parse($text, $DocOpts) }

# jq's ordering: null < false < true < numbers < strings < anything else.
function CmpVal($a, $b) {
  $ra = TypeRank $a; $rb = TypeRank $b
  if ($ra -ne $rb) { return $ra.CompareTo($rb) }
  if ($ra -eq 3) { return ([double]$a).CompareTo([double]$b) }
  if ($ra -eq 4) { return [Math]::Sign([string]::CompareOrdinal($a, $b)) }
  return 0
}
function TypeRank($x) {
  if ($null -eq $x) { return 0 }
  if ($x -is [bool]) { if ($x) { return 2 }; return 1 }
  if (IsNum $x) { return 3 }
  if ($x -is [string]) { return 4 }
  return 5
}

# Stable multi-key sort, like jq's sort_by. $keyFn returns an array of keys.
function SortBy($items, [scriptblock]$keyFn) {
  $rows = [System.Collections.Generic.List[object]]::new()
  $i = 0
  foreach ($it in $items) { $rows.Add(@{ k = (& $keyFn $it); i = $i; v = $it }); $i++ }
  $rows.Sort([Comparison[object]] {
      param($x, $y)
      $n = [Math]::Max($x.k.Count, $y.k.Count)
      for ($j = 0; $j -lt $n; $j++) {
        $c = CmpVal $(if ($j -lt $x.k.Count) { $x.k[$j] }) $(if ($j -lt $y.k.Count) { $y.k[$j] })
        if ($c -ne 0) { return $c }
      }
      return $x.i.CompareTo($y.i)
    })
  $res = foreach ($r in $rows) { , $r.v }
  return , @($res)
}

# Sorted unique values (jq's unique).
function UniqueSorted($items) {
  $seen = @{}; $out = [System.Collections.Generic.List[object]]::new()
  foreach ($x in $items) { $k = KeyOf @($x); if (-not $seen.ContainsKey($k)) { $seen[$k] = 1; $out.Add($x) } }
  return , (SortBy $out { param($x) , @($x) })
}

# A dictionary key for a tuple of scalars that tells null from "null".
function KeyOf($parts) {
  $s = foreach ($p in $parts) { if ($null -eq $p) { 'n' } else { 's' + (ToJqString $p) } }
  return (@($s) -join [char]0)
}

# jq's group_by: groups sorted by key, original order inside a group.
function GroupBy($items, [scriptblock]$keyFn) {
  $groups = [ordered]@{}; $keys = @{}
  foreach ($it in $items) {
    $k = & $keyFn $it; $ks = KeyOf $k
    if (-not $groups.Contains($ks)) { $groups[$ks] = [System.Collections.Generic.List[object]]::new(); $keys[$ks] = $k }
    $groups[$ks].Add($it)
  }
  $list = foreach ($ks in $groups.Keys) { , @{ k = $keys[$ks]; g = $groups[$ks].ToArray() } }
  # Emits one array per group: callers wrap the call in @().
  foreach ($x in (SortBy @($list) { param($x) , $x.k })) { , $x.g }
}

function MaxOf($items) {
  $m = $null; $any = $false
  foreach ($x in $items) { if (-not $any -or (CmpVal $x $m) -gt 0) { $m = $x; $any = $true } }
  return $m
}

function Utc($at) {
  if ((IsNum $at) -and $at -ge 0 -and $at -lt 32503680000000) {
    return [DateTimeOffset]::FromUnixTimeSeconds([long][Math]::Floor($at / 1000)).UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss', $Inv)
  }
  return $null
}

function NormModel($m) {
  if ($m -isnot [string]) { return '' }
  $m = $m.ToLowerInvariant() -creplace '\[.*$', '' -creplace '^claude-', '' -creplace '-[0-9]{8}$', ''
  return $m
}

# Text table: columns padded to their widest cell, two spaces apart.
function Table($rows) {
  if ($rows.Count -eq 0) { return }
  $nc = ($rows | ForEach-Object { $_.Count } | Measure-Object -Maximum).Maximum
  $w = for ($i = 0; $i -lt $nc; $i++) {
    ($rows | ForEach-Object { if ($i -lt $_.Count) { ([string]$_[$i]).Length } else { 0 } } | Measure-Object -Maximum).Maximum
  }
  foreach ($r in $rows) {
    $cells = for ($i = 0; $i -lt $nc; $i++) { $c = ''; if ($i -lt $r.Count) { $c = [string]$r[$i] }; $c.PadRight($w[$i]) }
    Say ((@($cells) -join '  ').TrimEnd(' '))
  }
}

$TmpList = [System.Collections.Generic.List[string]]::new()
function MakeTmp([string]$dir) {
  $p = Join-Path $dir ('.am-i-nerfed.' + [IO.Path]::GetRandomFileName().Replace('.', ''))
  try { [IO.File]::WriteAllBytes($p, [byte[]]@()) } catch { Die "cannot create a temporary file in $(Tildify $dir)" }
  $TmpList.Add($p)
  return $p
}
function CleanTmp { if (-not (Test-Path variable:script:TmpList)) { return }; foreach ($f in $TmpList) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } } }

# DIR\NAME.<UTC timestamp>[_NN]SUFFIX; names sort chronologically.
function UniquePath([string]$dir, [string]$name, [string]$suffix) {
  $base = Join-Path $dir ("$name." + [DateTime]::UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'", $Inv))
  $p = "$base$suffix"; $n = 0
  while (Test-Path -LiteralPath $p) { $n++; $p = '{0}_{1:D2}{2}' -f $base, $n, $suffix }
  return $p
}

# Follow symlinks so the atomic replacement writes the real file, not over the link.
function ResolveLink([string]$p) {
  if (-not (Test-Path -LiteralPath $p)) { return $p }
  $t = ([IO.FileInfo]::new($p)).ResolveLinkTarget($true)
  if ($null -eq $t) { return $p }
  return $t.FullName
}

function Sha([string]$p) { return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash }
function SameFile([string]$a, [string]$b) { return ((Test-Path -LiteralPath $a) -and (Test-Path -LiteralPath $b) -and (Sha $a) -eq (Sha $b)) }

# Copy and check the copy byte for byte.
function VerifiedCopy([string]$src, [string]$dst) {
  try { Copy-Item -LiteralPath $src -Destination $dst -Force } catch { return $false }
  return (SameFile $src $dst)
}

# Replace TARGET with TMP in one step; File.Replace keeps the target's ACL and attributes.
function ReplaceFile([string]$tmp, [string]$target) {
  if (Test-Path -LiteralPath $target) { [IO.File]::Replace($tmp, $target, [NullString]::Value) }
  else { [IO.File]::Move($tmp, $target) }
}

function Utf8NoBom { return [Text.UTF8Encoding]::new($false) }

# Serialize a JsonNode the way Claude Code writes JSON (JSON.stringify(x, null, 2)):
# 2-space indent, LF, raw non-ASCII, no final newline. Numbers keep their
# original text, so integers beyond 2^53 survive. On a real config, an optout
# changes no byte other than the removed keys.
function NodeToText($node) {
  $o = [System.Text.Json.JsonSerializerOptions]::new()
  $o.WriteIndented = $true
  $o.Encoder = [System.Text.Encodings.Web.JavaScriptEncoder]::UnsafeRelaxedJsonEscaping
  return $node.ToJsonString($o).Replace("`r`n", "`n")
}

# The comma stops PowerShell from unrolling the JsonObject into key/value pairs.
function ParseNode([string]$text) { return , [System.Text.Json.Nodes.JsonNode]::Parse($text, $null, $DocOpts) }

# Returns $null when the edit may go ahead, otherwise the line to print instead.
# (Printing here would end up in the return value.)
function Refusal([string]$q) {
  if ($script:AssumeYes) { return $null }
  if (-not [Console]::IsInputRedirected) {
    [Console]::Out.Write("$q [y/N] ")
    $ans = [Console]::In.ReadLine()
    if ($ans -match '^(?i:y|yes)$') { return $null }
    return 'Not applied.'
  }
  return 'Not applied: stdin is not a terminal. Re-run with --yes to apply it without a prompt.'
}

function NewestBackup([string]$prefix) {
  if (-not (Test-Path -LiteralPath $BACKUP_DIR)) { return $null }
  $names = @(Get-ChildItem -LiteralPath $BACKUP_DIR -File -Force |
      Where-Object { $_.Name.StartsWith("$prefix.", [StringComparison]::Ordinal) -and $_.Name.EndsWith('.bak', [StringComparison]::Ordinal) } |
      ForEach-Object { $_.Name })
  if ($names.Count -eq 0) { return $null }
  [Array]::Sort($names, [StringComparer]::Ordinal)
  return (Join-Path $BACKUP_DIR $names[-1])
}

# UTC time of the newest optout as "yyyy-MM-ddTHH:mm:ssZ", or $null when there
# was none or a restore happened after it.
function LastOptout {
  $o = NewestBackup 'claude.json'
  $r = NewestBackup 'pre-restore.claude.json'
  if (-not $o) { return $null }
  $ots = ((Split-Path -Leaf $o).Substring('claude.json.'.Length) -replace '\.bak$', '') -replace '_.*$', ''
  if ($r) {
    $rts = ((Split-Path -Leaf $r).Substring('pre-restore.claude.json.'.Length) -replace '\.bak$', '') -replace '_.*$', ''
    if ([string]::CompareOrdinal($rts, $ots) -ge 0) { return $null }
  }
  if ($ots -cmatch '^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$') {
    return '{0}-{1}-{2}T{3}:{4}:{5}Z' -f $Matches[1], $Matches[2], $Matches[3], $Matches[4], $Matches[5], $Matches[6]
  }
  return $null
}

# ------------------------------------------------------------------- paths --
# Mirrors Claude Code: with CLAUDE_CONFIG_DIR set, everything lives inside it;
# otherwise the config file is ~\.claude.json and the rest is under ~\.claude.

if ($env:CLAUDE_CONFIG_DIR) {
  $CONFIG_HOME = [IO.Path]::GetFullPath($env:CLAUDE_CONFIG_DIR, $PWD.ProviderPath).TrimEnd('\', '/')
  $CONFIG_FILE = Join-Path $CONFIG_HOME '.claude.json'
} else {
  if (-not $UserHome) { Die 'USERPROFILE is not set' }
  $CONFIG_HOME = Join-Path $UserHome '.claude'
  $CONFIG_FILE = Join-Path $UserHome '.claude.json'
}
$PROJECTS_DIR = Join-Path $CONFIG_HOME 'projects'
$SETTINGS_FILE = Join-Path $CONFIG_HOME 'settings.json'
$BACKUP_DIR = Join-Path (Join-Path $CONFIG_HOME 'am-i-nerfed') 'backups'
$script:AssumeYes = $false

# ---------------------------------------------------------------- analysis --

# Reads only what the analysis needs: the org, the slots (as native objects)
# and the size of cachedExperimentData. Exits 2 if the file is not a JSON object.
function ReadConfig([string]$path) {
  try { $doc = ParseJson ([IO.File]::ReadAllText($path)) } catch { $doc = $null }
  if ($null -eq $doc -or $doc.RootElement.ValueKind -ne 'Object') {
    Die "$(Tildify $path) is not a valid JSON object (Claude Code may be writing it right now; retry in a moment)."
  }
  $cfg = @{ org = $null; slots = @(); ced = $null }
  foreach ($p in $doc.RootElement.EnumerateObject()) {
    switch -CaseSensitive ($p.Name) {
      'oauthAccount' {
        $cfg.org = $null
        if ($p.Value.ValueKind -eq 'Object') {
          foreach ($q in $p.Value.EnumerateObject()) { if ($q.Name -ceq 'organizationUuid') { $cfg.org = NonEmptyStr (FromJE $q.Value) } }
        }
      }
      'clientDataCacheSlots' {
        $list = [System.Collections.Generic.List[object]]::new()
        if ($p.Value.ValueKind -eq 'Object') { foreach ($q in $p.Value.EnumerateObject()) { $list.Add($q.Value) } }
        elseif ($p.Value.ValueKind -eq 'Array') { foreach ($q in $p.Value.EnumerateArray()) { $list.Add($q) } }
        $cfg.slots = @($list | Where-Object { $_.ValueKind -eq 'Object' } | ForEach-Object { , (FromJE $_) })
      }
      'cachedExperimentData' {
        $cfg.ced = $null
        if ($p.Value.ValueKind -eq 'Object') { $cfg.ced = @($p.Value.EnumerateObject()).Count }
        elseif ($p.Value.ValueKind -eq 'Array') { $cfg.ced = $p.Value.GetArrayLength() }
      }
    }
  }
  return $cfg
}

# One cache slot -> normalized record. Never carries the org value itself.
function SlotRec($s, $org, [bool]$full) {
  $d = $null; if (IsObj $s['data']) { $d = $s['data'] }
  $a = $null; $k = $null
  if ($null -ne $d) { $a = $d['atis']; $k = $d['experimentKey'] }
  if ($null -eq $d) { $state = 'unknown' }
  elseif ($a -is [string] -and $a.Length -gt 0) { $state = 'assigned' }
  elseif ($null -ne $a -and -not ($a -is [string])) { $state = 'unknown' }
  elseif ($null -ne $k) { $state = 'unknown' }
  else { $state = 'unassigned' }
  $at = $null; if (IsNum $s['at']) { $at = $s['at'] }
  $ek = $null; if ($null -ne $k) { $ek = ToJqString $k }
  $orgState = 'unknown'
  if ($null -ne $org -and $s['org'] -is [string]) { if ($s['org'] -ceq $org) { $orgState = 'current' } else { $orgState = 'other' } }
  $r = [ordered]@{
    model         = NonEmptyStr $s['model']
    entrypoint    = NonEmptyStr $s['entrypoint']
    at            = $at
    time          = Utc $s['at']
    state         = $state
    id            = $(if ($state -eq 'assigned') { $a.Substring(0, [Math]::Min(3, $a.Length)) } else { $null })
    experimentKey = $ek
    org           = $orgState
  }
  if ($full -and $state -eq 'assigned') { $r['atis'] = $a }
  return , $r
}

function AtOr($r, $dflt) { if ($null -eq $r.at) { return $dflt }; return $r.at }

# All slots; current = newest slot for its (model, entrypoint) among slots that
# are not from another organization.
function AllRecs($cfg, [bool]$full) {
  $recs = @(foreach ($s in $cfg.slots) { , (SlotRec $s $cfg.org $full) })
  $newest = @{}
  foreach ($r in $recs) {
    if ($r.org -eq 'other') { continue }
    $k = KeyOf @($r.model, $r.entrypoint); $at = AtOr $r -1
    if (-not $newest.ContainsKey($k) -or $at -gt $newest[$k]) { $newest[$k] = $at }
  }
  foreach ($r in $recs) {
    $k = KeyOf @($r.model, $r.entrypoint)
    $r['current'] = ($r.org -ne 'other' -and $newest.ContainsKey($k) -and (AtOr $r -1) -eq $newest[$k])
  }
  return , $recs
}

function ModelVerdict($rs) {
  $cur = @($rs | Where-Object { $_.current })
  $asg = @($cur | Where-Object { $_.state -eq 'assigned' })
  $cln = @($cur | Where-Object { $_.state -eq 'unassigned' })
  $asof = MaxOf @($cur | Where-Object { $null -ne $_.at } | ForEach-Object { $_.at })
  if ($asg.Count -gt 0) { $verdict = 'ENROLLED' } elseif ($cln.Count -gt 0) { $verdict = 'CLEAN' } else { $verdict = 'INCONCLUSIVE' }
  $reason = $null
  if ($asg.Count -eq 0 -and $cln.Count -eq 0) {
    if (@($rs | Where-Object { $_.org -ne 'other' }).Count -eq 0) { $reason = 'only slots from a different organization' }
    else { $reason = 'no slot with readable assignment data' }
  }
  return , ([ordered]@{
      model                  = $rs[0].model
      verdict                = $verdict
      ids                    = UniqueSorted @($asg | ForEach-Object { $_.id })
      enrolled               = @($asg | ForEach-Object { , ([ordered]@{ entrypoint = $_.entrypoint; id = $_.id; experimentKey = $_.experimentKey; time = $_.time }) })
      as_of                  = $asof
      as_of_time             = Utc $asof
      entrypoints            = UniqueSorted @($cur | ForEach-Object { Coalesce $_.entrypoint '-' })
      superseded_assignments = @($rs | Where-Object { -not $_.current -and $_.org -ne 'other' -and $_.state -eq 'assigned' } |
          ForEach-Object { , ([ordered]@{ entrypoint = $_.entrypoint; id = $_.id; time = $_.time }) })
      reason                 = $reason
      slots                  = $rs.Count
    })
}

function NoSlotModel([string]$m, [string]$why) {
  return , ([ordered]@{ model = $m; verdict = 'INCONCLUSIVE'; ids = @(); enrolled = @(); as_of = $null; as_of_time = $null
      entrypoints = @(); superseded_assignments = @(); reason = $why; slots = 0 })
}

# cachedExperimentData holds ordinary named feature-flag experiments, separate
# from the x-cc-atis assignment. Only its size is used; names and values never are.
function Analyze($cfg, [string]$want, [bool]$full) {
  $recs = AllRecs $cfg $full
  $all = @(foreach ($g in @(GroupBy $recs { param($r) , @($r.model) })) { , (ModelVerdict $g) })
  $all = SortBy $all { param($m) , @(- [double](Coalesce $m.as_of 0)) }
  if ($want -eq '') { $models = $all }
  else {
    $nw = NormModel $want
    $models = @($all | Where-Object { (NormModel $_.model) -eq $nw })
    if ($models.Count -eq 0) { $models = @(NoSlotModel $want 'no slot for this model') }
  }
  $rank = @{}
  for ($i = 0; $i -lt $models.Count; $i++) { $rank[(KeyOf @($models[$i].model))] = $i }
  $shown = @($recs | Where-Object { $want -eq '' -or (NormModel $_.model) -eq (NormModel $want) })
  $shown = SortBy $shown { param($r) $k = KeyOf @($r.model); $rk = 999; if ($rank.ContainsKey($k)) { $rk = $rank[$k] }; , @($rk, - [double](Coalesce $r.at 0)) }
  if (@($models | Where-Object { $_.verdict -eq 'ENROLLED' }).Count -gt 0) { $status = 'enrolled' }
  elseif ($models.Count -eq 0 -or @($models | Where-Object { $_.verdict -eq 'INCONCLUSIVE' }).Count -gt 0) { $status = 'inconclusive' }
  else { $status = 'clean' }
  $rc = 3; if ($status -eq 'clean') { $rc = 0 } elseif ($status -eq 'enrolled') { $rc = 1 }
  return [ordered]@{
    status                       = $status
    exit_code                    = $rc
    slot_count                   = $recs.Count
    cached_experiment_data_count = $cfg.ced
    models                       = $models
    slots                        = $shown
  }
}

# ------------------------------------------------------------------- usage --

function Usage {
  @"
am-i-nerfed $AMN_VERSION (Windows): detect, explain and opt out of Claude Code
experiment assignments (the x-cc-atis request header). Unofficial.

Usage: pwsh -File $PROG [command] [options]

Commands:
  check        (default) list every cached experiment slot and give a verdict per model
                 --json        machine-readable output
                 --full        show whole assignment tokens (may identify you; do not share)
                 --model ID    only this model, e.g. claude-opus-5-5 (no slot = INCONCLUSIVE)
               exit status: 0 clean, 1 enrolled, 3 inconclusive, 2 error
  history      tally experiment IDs recorded in session transcripts, by UTC date
                 --json, --full
  optout       back up the config file, delete data.atis and data.experimentKey from
               every slot, then explain the env var users report blocks re-enrollment
                 --dry-run              show what would change; change nothing
                 --apply-env[=settings] also set $ENV_VAR in settings.json "env"
                 --apply-env=user       ...or set it as a Windows user environment variable
                 --yes                  apply --apply-env edits without asking
  restore      put back the newest optout backup (the current file is saved first)
  statusline   print a ready-to-paste status line snippet (exp:<id>, exp:none, exp:?)
                 --render               the status line command itself (reads Claude Code JSON on stdin)

Files (CLAUDE_CONFIG_DIR is honored):
  config       $(Tildify $CONFIG_FILE)
  transcripts  $(Tildify $PROJECTS_DIR)
  backups      $(Tildify $BACKUP_DIR)

Reads undocumented Claude Code internals and may break on any release. Makes no
network calls. Never prints account or OAuth values.
"@ -split "`r?`n" | ForEach-Object { Say $_ }
}

function SelfCmd { return "pwsh -File `"$PSCommandPath`"" }

# ------------------------------------------------------------------- check --

function CmdCheck($rest) {
  $fmt = 'text'; $full = $false; $model = ''
  for ($i = 0; $i -lt $rest.Count; $i++) {
    $a = [string]$rest[$i]
    switch -CaseSensitive -Regex ($a) {
      '^--json$' { $fmt = 'json'; break }
      '^--full$' { $full = $true; break }
      '^--model$' { if ($i + 1 -ge $rest.Count) { DieUsage 'check: --model needs a model ID' }; $i++; $model = [string]$rest[$i]; break }
      '^--model=' { $model = $a.Substring(8); break }
      '^(-h|--help)$' { Usage; exit 0 }
      default { DieUsage "check: unknown option: $a" }
    }
  }
  $present = Test-Path -LiteralPath $CONFIG_FILE -PathType Leaf
  if ($present) { $cfg = ReadConfig $CONFIG_FILE } else { $cfg = @{ org = $null; slots = @(); ced = $null } }
  $r = Analyze $cfg $model $full
  $optout = LastOptout
  $optoutMs = $null
  if ($optout) { $optoutMs = [DateTimeOffset]::Parse($optout, $Inv).ToUnixTimeMilliseconds() }
  $after = @()
  if ($null -ne $optoutMs) { $after = @($r.slots | Where-Object { (Coalesce $_.at 0) -gt $optoutMs }) }

  if ($fmt -eq 'json') {
    $o = [ordered]@{
      tool           = 'am-i-nerfed'
      version        = $AMN_VERSION
      generated_at   = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $Inv)
      config_file    = $CONFIG_FILE
      config_present = [bool]$present
    }
    foreach ($k in $r.Keys) { $o[$k] = $r[$k] }
    $o['last_optout'] = $optout
    $o['slots_written_after_last_optout'] = $(if ($null -eq $optoutMs) { $null } else { $after.Count })
    Say (ConvertTo-Json -InputObject $o -Depth 20)
    exit $r.exit_code
  }

  Say "am-i-nerfed ${AMN_VERSION}: $(Tildify $CONFIG_FILE)"
  Say
  if (-not $present) {
    Say 'No Claude Code config file here. Claude Code has not run with this config directory,'
    Say 'or CLAUDE_CONFIG_DIR points somewhere else.'
  } elseif ($r.slot_count -eq 0) {
    Say 'No experiment-cache slots (clientDataCacheSlots) in this file. Claude Code may not have'
    Say 'fetched remote flags yet, or this version keeps them somewhere else (see COMPAT.md).'
  } elseif ($r.slots.Count -eq 0) {
    Say "$($r.slot_count) experiment-cache slot(s), none for this model."
  } else {
    $hdr = "$($r.slot_count) experiment-cache slot(s)"
    if ($r.slots.Count -lt $r.slot_count) { $hdr += ", $($r.slots.Count) shown" }
    Say "${hdr}:"
    Say
    $rows = [System.Collections.Generic.List[object]]::new()
    $tokHdr = 'ID'; if ($full) { $tokHdr = 'TOKEN' }
    $rows.Add(@('MODEL', 'ENTRYPOINT', 'SLOT TIME (UTC)', $tokHdr, 'EXPERIMENT KEY', 'NOTE'))
    foreach ($s in $r.slots) {
      if ($s.org -eq 'other') { $note = 'other org, ignored' } elseif ($s.current) { $note = 'newest' } else { $note = 'superseded' }
      if ($s.state -eq 'unknown') { $note += ', unreadable' }
      $tok = $s.id; if ($full) { $tok = $s['atis'] }
      $rows.Add(@((Coalesce $s.model '-'), (Coalesce $s.entrypoint '-'), (Coalesce $s.time '-'), (Coalesce $tok '-'), (Coalesce $s.experimentKey '-'), $note))
    }
    Table $rows
  }
  Say
  Say 'Verdict per model:'
  if ($r.models.Count -eq 0) { Say '  none (no slots to judge)' }
  else {
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($m in $r.models) {
      if ($m.verdict -eq 'ENROLLED') {
        $parts = foreach ($e in $m.enrolled) {
          $t = "ID $($e.id) via $(Coalesce $e.entrypoint 'unknown entrypoint')"
          if ($null -ne $e.experimentKey) { $t += ", experimentKey $($e.experimentKey)" }
          $t
        }
        $vt = 'ENROLLED (' + (@($parts) -join '; ') + ')'
      } elseif ($m.verdict -eq 'CLEAN') {
        $vt = "CLEAN as of $(Coalesce $m.as_of_time 'an unknown time') UTC (state after that time unknown)"
      } else { $vt = "INCONCLUSIVE ($(Coalesce $m.reason 'no slot'))" }
      $rows.Add(@(('  ' + (Coalesce $m.model '(no model name)')), $vt))
    }
    Table $rows
  }
  foreach ($m in $r.models) {
    foreach ($s in $m.superseded_assignments) {
      Say "  note: $(Coalesce $m.model '?'): an older, superseded $(Coalesce $s.entrypoint '?') slot from $(Coalesce $s.time '?') UTC carried ID $($s.id)."
    }
  }
  if ($after.Count -gt 0) {
    Say "  note: slots were written after your last optout ($($optout.Replace('T', ' ').TrimEnd('Z')) UTC), so Claude Code"
    Say "        is still fetching remote flags: either $ENV_VAR=1 is not set for every launch,"
    Say '        or it does not block refreshes.'
  }
  Say
  Say "Overall: $($r.status.ToUpperInvariant()) (exit $($r.exit_code))"
  if ($null -ne $r.cached_experiment_data_count -and $r.cached_experiment_data_count -gt 0) {
    Say "Not checked: $($r.cached_experiment_data_count) named feature-flag experiment(s) in cachedExperimentData (ordinary flags, not x-cc-atis)."
  }
  if (@($r.slots | Where-Object { $_.state -eq 'assigned' }).Count -gt 0) {
    Say
    Say 'ID = first 3 characters of the slot assignment token (data.atis), which Claude Code sends as'
    if ($full) { Say 'the x-cc-atis request header. Whole tokens are shown (--full): they may be tied to your account, so do not post them.' }
    else { Say 'the x-cc-atis request header. Whole tokens are hidden; --full shows them.' }
  }
  if ($r.slot_count -gt 0) {
    Say 'Verdicts describe what Claude Code last cached on this machine. The server can assign,'
    Say 'change or end an experiment at any refresh, even mid-session.'
  }
  if ($r.status -eq 'enrolled') {
    Say "To opt out: quit every Claude Code session (CLI and Desktop), then run: $(SelfCmd) optout"
  }
  exit $r.exit_code
}

# ----------------------------------------------------------------- history --

# Top-level fields of one transcript line, or $null when it is not a JSON object.
function LineFields([string]$line) {
  try { $root = (ParseJson $line).RootElement } catch { return $null }
  if ($root.ValueKind -ne 'Object') { return $null }
  $f = @{ ts = $null; type = $null; sid = $null; atis = '' }
  foreach ($p in $root.EnumerateObject()) {
    $k = $p.Value.ValueKind
    switch -CaseSensitive ($p.Name) {
      'timestamp' { $f.ts = $null; if ($k -eq 'String') { $x = $p.Value.GetString(); if ($x.Length -ge 10) { $f.ts = $x } } }
      'type' { $f.type = $null; if ($k -eq 'String') { $f.type = $p.Value.GetString() } }
      'sessionId' { $f.sid = $null; if ($k -eq 'String') { $f.sid = NonEmptyStr $p.Value.GetString() } }
      'atis' { $f.atis = ''; if ($k -eq 'String') { $f.atis = $p.Value.GetString() } }
    }
  }
  return $f
}
function LineTs([string]$line) { $f = LineFields $line; if ($null -eq $f) { return $null }; return $f.ts }

# The whole line around position $i of $text.
function LineAt([string]$text, [int]$i) {
  $s = 0; if ($i -gt 0) { $s = $text.LastIndexOf([char]10, $i - 1) + 1 }
  $e = $text.IndexOf([char]10, $i); if ($e -lt 0) { $e = $text.Length }
  return @{ s = $s; e = $e; line = $text.Substring($s, $e - $s) }
}

# Emits one record per {"type":"atis-latch"} transcript entry. The entry has no
# timestamp of its own, so it is dated by the nearest earlier timestamped entry
# in the same file (or the first one, when it comes before any).
# Transcripts can add up to tens of GB and a PowerShell loop over every line is
# slow, so each file is searched as one string: jump to each line mentioning
# atis-latch, then walk back over the lines mentioning "timestamp" and parse
# them, newest first, until one has a top-level timestamp.
function ScanTranscript([string]$path, [string]$text, [bool]$full, $out) {
  $O = [StringComparison]::Ordinal
  $last = $null; $done = 0   # $last = newest timestamp in $text[0..$done)
  $found = [System.Collections.Generic.List[object]]::new()
  $i = $text.IndexOf('atis-latch', $O)
  while ($i -ge 0) {
    $L = LineAt $text $i
    $p = $L.s
    while ($p -gt $done) {
      $j = $text.LastIndexOf('"timestamp"', $p - 1, $p - $done, $O)
      if ($j -lt 0) { break }
      $C = LineAt $text $j
      $t = LineTs $C.line
      if ($null -ne $t) { $last = $t; break }
      $p = $C.s
    }
    $f = LineFields $L.line
    if ($null -ne $f) {
      if ($null -ne $f.ts) { $last = $f.ts }
      if ($f.type -ceq 'atis-latch') { $found.Add(@{ ts = $last; sid = $f.sid; atis = $f.atis }) }
    }
    $done = $L.e
    $i = -1; if ($L.e -lt $text.Length) { $i = $text.IndexOf('atis-latch', $L.e, $O) }
  }
  # Entries before any timestamp take the file's first timestamp.
  $first = $null
  if (@($found | Where-Object { $null -eq $_.ts }).Count -gt 0) {
    $j = $text.IndexOf('"timestamp"', $O)
    while ($j -ge 0 -and $null -eq $first) {
      $C = LineAt $text $j
      $first = LineTs $C.line
      $j = -1; if ($C.e -lt $text.Length) { $j = $text.IndexOf('"timestamp"', $C.e, $O) }
    }
  }
  $fallback = [IO.Path]::GetFileNameWithoutExtension($path)
  foreach ($e in $found) {
    $ts = Coalesce $e.ts $first
    $rec = [ordered]@{
      fn      = $path
      date    = $(if ($null -eq $ts) { 'unknown' } else { $ts.Substring(0, 10) })
      session = Coalesce $e.sid $fallback
      id      = $(if ($e.atis.Length -gt 0) { $e.atis.Substring(0, [Math]::Min(3, $e.atis.Length)) } else { $null })
    }
    if ($full -and $e.atis.Length -gt 0) { $rec['atis'] = $e.atis }
    $out.Add($rec)
  }
}

function CountUnique($items) { $h = @{}; foreach ($x in $items) { $h[[string]$x] = 1 }; return $h.Count }

function CmdHistory($rest) {
  $fmt = 'text'; $full = $false
  foreach ($a in $rest) {
    switch -CaseSensitive ([string]$a) {
      '--json' { $fmt = 'json' }
      '--full' { $full = $true }
      { $_ -ceq '-h' -or $_ -ceq '--help' } { Usage; exit 0 }
      default { DieUsage "history: unknown option: $a" }
    }
  }
  $files = @()
  if (Test-Path -LiteralPath $PROJECTS_DIR -PathType Container) {
    $files = @(Get-ChildItem -LiteralPath $PROJECTS_DIR -Recurse -File -Force -Filter '*.jsonl' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name.EndsWith('.jsonl', [StringComparison]::Ordinal) } | ForEach-Object { $_.FullName })
  }
  $total = $files.Count
  if ($total -eq 0) {
    if ($fmt -eq 'json') {
      Say (ConvertTo-Json -Depth 5 -InputObject ([ordered]@{ tool = 'am-i-nerfed'; version = $AMN_VERSION; transcripts_dir = $PROJECTS_DIR
            files_scanned = 0; files_with_records = 0; field = 'atis-latch'; sessions = 0; sessions_with_id = 0; by_date = @(); ids = @()
            note = 'no session transcripts found' }))
    } else {
      Say "am-i-nerfed ${AMN_VERSION}: history from $(Tildify $PROJECTS_DIR)"
      Say
      Say 'No session transcripts (*.jsonl) here. Nothing to tally.'
    }
    exit 0
  }
  $recs = [System.Collections.Generic.List[object]]::new()
  foreach ($f in $files) {
    try { $text = [IO.File]::ReadAllText($f) } catch { continue }
    if ($text.Contains('atis-latch')) { ScanTranscript $f $text $full $recs }
  }

  $byDate = foreach ($g in @(GroupBy $recs { param($x) , @($x.date, (Coalesce $x.id '')) })) {
    , ([ordered]@{ date = $g[0].date; id = (Coalesce $g[0].id 'none'); sessions = (CountUnique ($g | ForEach-Object { $_.session })); records = $g.Count })
  }
  $byDate = SortBy @($byDate) { param($x) , @($x.date, $x.id) }
  $withId = @($recs | Where-Object { $null -ne $_.id })
  $ids = foreach ($g in @(GroupBy $withId { param($x) , @($x.id) })) {
    $dates = @($g | ForEach-Object { $_.date }); [Array]::Sort($dates, [StringComparer]::Ordinal)
    $e = [ordered]@{ id = $g[0].id; sessions = (CountUnique ($g | ForEach-Object { $_.session })); first_date = $dates[0]; last_date = $dates[-1] }
    if ($full) { $e['tokens'] = UniqueSorted @($g | ForEach-Object { $_['atis'] } | Where-Object { $null -ne $_ }) }
    , $e
  }
  $ids = @($ids)
  $s = [ordered]@{
    files_with_records = (CountUnique ($recs | ForEach-Object { $_.fn }))
    sessions           = (CountUnique ($recs | ForEach-Object { $_.session }))
    sessions_with_id   = (CountUnique ($withId | ForEach-Object { $_.session }))
    by_date            = $byDate
    ids                = $ids
  }

  if ($fmt -eq 'json') {
    $o = [ordered]@{ tool = 'am-i-nerfed'; version = $AMN_VERSION; transcripts_dir = $PROJECTS_DIR; files_scanned = $total; field = 'atis-latch' }
    foreach ($k in $s.Keys) { $o[$k] = $s[$k] }
    if ($s.files_with_records -eq 0) { $o['note'] = 'no atis-latch entries found in any transcript' }
    Say (ConvertTo-Json -InputObject $o -Depth 10)
    exit 0
  }
  Say "am-i-nerfed ${AMN_VERSION}: history from $(Tildify $PROJECTS_DIR)"
  Say
  if ($s.files_with_records -eq 0) {
    Say "No experiment identifiers found. None of the $total transcript file(s) contains an"
    Say 'atis-latch entry, which is the only place Claude Code was seen recording the assignment in'
    Say 'transcripts (Claude Code 2.1.291 to 2.1.319, see COMPAT.md). This Claude Code version may not'
    Say 'record it, or these sessions predate the field. Nothing to tally.'
    exit 0
  }
  Say "Scanned $total transcript file(s); $($s.files_with_records) contain atis-latch entries."
  Say
  $rows = [System.Collections.Generic.List[object]]::new()
  $rows.Add(@('DATE (UTC)', 'ID', 'SESSIONS', 'ENTRIES'))
  foreach ($d in $byDate) { $rows.Add(@($d.date, $d.id, $d.sessions, $d.records)) }
  Table $rows
  Say
  Say "Sessions that recorded an experiment ID: $($s.sessions_with_id) of $($s.sessions)."
  if ($ids.Count -gt 0) {
    Say ('IDs seen: ' + (@($ids | ForEach-Object { "$($_.id) ($($_.sessions) session(s), $($_.first_date) to $($_.last_date))" }) -join '; '))
    if ($full) { foreach ($e in $ids) { Say "  $($e.id): $(@($e.tokens) -join ', ')" } }
  }
  Say '"none" = an atis-latch entry with an empty value: no assignment recorded at that point.'
  Say 'Dates come from the nearest earlier timestamped entry in the same transcript.'
  exit 0
}

# ------------------------------------------------------------------ optout --

function EnvAdvice {
  @"

Blocking re-enrollment
  1. Quit every Claude Code session, CLI and Desktop. A session that is still running can
     write its cached assignment back.
  2. Users report that deleting the keys is not enough on its own, because the next remote
     refresh re-enrolls you, and that starting Claude Code with this variable set blocks
     that; not verified by this project:

       `$env:$ENV_VAR = '1'      (PowerShell, this window only)

     Users also report that DISABLE_GROWTHBOOK=1 on its own no longer blocks it; not verified
     by this project. To set the variable for every launch, re-run with --apply-env (sets it
     in $(Tildify $SETTINGS_FILE) "env") or --apply-env=user (sets it as a
     Windows user environment variable).
  3. Later, run "$PROG check": a slot time newer than this optout means Claude Code is still
     fetching flags, so either the variable is not set for that launch path or it does not
     block refreshes.

What else $ENV_VAR=1 turns off
  Anthropic documents it as equivalent to setting DISABLE_AUTOUPDATER, DISABLE_BUG_COMMAND,
  DISABLE_ERROR_REPORTING and DISABLE_TELEMETRY together:
  - Automatic updates. Claude Code stops updating itself; run "claude update" by hand.
  - Usage telemetry and error reports to Anthropic.
  - The /bug feedback command.
  Users report that it also stops every remote feature-flag update, not only experiments,
  so that new features, staged rollouts and fixes shipped as flags stop arriving and the
  flags already cached stay frozen; not verified by this project. It may stop other
  background requests too. Unset it to undo all of this.
"@ -split "`r?`n" | ForEach-Object { Say $_ }
}

function SlotsWithAssignmentKeys($node) {
  $out = [System.Collections.Generic.List[object]]::new()
  $slots = $node['clientDataCacheSlots']
  $items = @()
  if ($slots -is [System.Text.Json.Nodes.JsonObject]) { $items = @(foreach ($kv in $slots.GetEnumerator()) { , $kv.Value }) }
  elseif ($slots -is [System.Text.Json.Nodes.JsonArray]) { $items = @(foreach ($x in $slots.GetEnumerator()) { , $x }) }
  foreach ($s in $items) {
    if ($s -isnot [System.Text.Json.Nodes.JsonObject]) { continue }
    $d = $s['data']
    if ($d -is [System.Text.Json.Nodes.JsonObject] -and ($d.ContainsKey('atis') -or $d.ContainsKey('experimentKey'))) { $out.Add($s) }
  }
  return , $out.ToArray()
}

function OptoutConfig([bool]$dry) {
  $target = ResolveLink $CONFIG_FILE
  $bytes = [IO.File]::ReadAllBytes($target)
  $before = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
  try { $node = ParseNode ((Utf8NoBom).GetString($bytes).TrimStart([char]0xFEFF)) } catch { Die "could not read slots from $(Tildify $target)" }
  $hits = SlotsWithAssignmentKeys $node
  if ($hits.Count -eq 0) {
    Say "Already clean: no slot in $(Tildify $target) has data.atis or data.experimentKey."
    Say 'Nothing changed; no backup made.'
    return
  }
  $plan = foreach ($s in $hits) {
    $n = FromJE ([System.Text.Json.JsonDocument]::Parse($s.ToJsonString()).RootElement)
    $id = '-'; $a = $n['data']['atis']; if ($a -is [string] -and $a.Length -gt 0) { $id = $a.Substring(0, [Math]::Min(3, $a.Length)) }
    "  - $(ToJqString (Coalesce $n['model'] 'unknown model')) via $(ToJqString (Coalesce $n['entrypoint'] 'unknown entrypoint')), slot $(Coalesce (Utc $n['at']) 'of unknown time') UTC: ID $id, experimentKey $(ToJqString (Coalesce $n['data']['experimentKey'] '-'))"
  }
  if ($dry) { Say "Dry run. Would remove data.atis and data.experimentKey from $($hits.Count) slot(s) in $(Tildify $target):" }
  else { Say "Removing data.atis and data.experimentKey from $($hits.Count) slot(s) in $(Tildify $target):" }
  foreach ($l in $plan) { Say $l }
  Say 'All other keys, including the other flags in those slots, stay as they are.'
  Say 'Close every Claude Code session (CLI and Desktop) first: a running one can write the assignment back.'
  if ($dry) { Say 'Nothing changed.'; return }

  try { New-Item -ItemType Directory -Force -Path $BACKUP_DIR | Out-Null } catch { Die "cannot create $(Tildify $BACKUP_DIR)" }
  $backup = UniquePath $BACKUP_DIR 'claude.json' '.bak'
  if (-not (VerifiedCopy $target $backup)) { Die "could not write a verified backup to $(Tildify $backup). Nothing changed." }

  foreach ($s in $hits) { $d = $s['data']; [void]$d.Remove('atis'); [void]$d.Remove('experimentKey') }
  $text = NodeToText $node
  $tmp = MakeTmp (Split-Path -Parent $target)
  try {
    [IO.File]::WriteAllText($tmp, $text, (Utf8NoBom))
    $back = [IO.File]::ReadAllText($tmp)
    $ok = ($back -ceq $text) -and ((SlotsWithAssignmentKeys (ParseNode $back)).Count -eq 0)
  } catch { $ok = $false }
  if (-not $ok) { CleanTmp; Die "the rewritten file did not verify. Nothing changed. Backup: $(Tildify $backup)" }
  $after = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($target)))
  if ($before -ne $after) {
    CleanTmp
    Die "$(Tildify $target) changed while am-i-nerfed was working (is Claude Code running?). Nothing changed; quit Claude Code and retry."
  }
  try { ReplaceFile $tmp $target } catch { CleanTmp; Die "could not replace $(Tildify $target); it is unchanged. Backup: $(Tildify $backup)" }
  Say "Done. Previous file backed up to $(Tildify $backup) (undo: $PROG restore)."
}

function ApplyEnvUser {
  if (-not $IsWindows) { Die '--apply-env=user sets a Windows user environment variable and only works on Windows.' }
  $cur = [Environment]::GetEnvironmentVariable($ENV_VAR, 'User')
  if ($cur -ceq '1') { Say "Already set as a user environment variable: $ENV_VAR=1"; return }
  Say
  Say 'Edit to your Windows user environment variables (HKCU\Environment):'
  if ($null -ne $cur) { Say "  - $ENV_VAR=$cur" }
  Say "  + $ENV_VAR=1"
  $no = Refusal 'Apply this edit?'
  if ($no) { Say $no; return }
  try { [Environment]::SetEnvironmentVariable($ENV_VAR, '1', 'User') } catch { Die "could not set the user environment variable: $_" }
  Say 'Done. Programs started from now on get it, the Claude Desktop app included once you restart'
  Say 'it. Terminals that are already open keep their old environment: open a new one.'
}

function ApplyEnvSettings {
  $f = $SETTINGS_FILE; $disp = Tildify $f; $target = $f; $node = $null; $cur = '<unset>'; $backup = $null
  if (Test-Path -LiteralPath $f) {
    $target = ResolveLink $f
    try { $node = ParseNode ([IO.File]::ReadAllText($target)) } catch { $node = $null }
    if ($node -isnot [System.Text.Json.Nodes.JsonObject]) {
      Die "$disp is not a plain JSON object (comments or a syntax error?); not editing it. Add `"env`": {`"$ENV_VAR`": `"1`"} by hand."
    }
    $envNode = $node['env']
    if ($null -ne $envNode -and $envNode -isnot [System.Text.Json.Nodes.JsonObject]) { Die "`"env`" in $disp is not an object; not editing it." }
    if ($null -ne $envNode -and $envNode.ContainsKey($ENV_VAR)) {
      $val = $envNode[$ENV_VAR]
      if ($null -eq $val) { $cur = 'null' } else { $cur = ToJqString (FromJE ([System.Text.Json.JsonDocument]::Parse($val.ToJsonString()).RootElement)) }
      if ($cur -ceq '1') { Say "Already set in ${disp}: `"env`": {`"$ENV_VAR`": `"1`"}"; return }
    }
  }
  Say
  if ($null -ne $node) { Say "Edit to $disp (other keys untouched; the file is re-indented):" } else { Say "New file ${disp}:" }
  Say '  "env": {'
  if ($cur -ne '<unset>') { Say "  -  `"$ENV_VAR`": $(ConvertTo-Json -InputObject $cur)" }
  Say "  +  `"$ENV_VAR`": `"1`""
  Say '  }'
  $no = Refusal 'Apply this edit?'
  if ($no) { Say $no; return }
  $dir = Split-Path -Parent $target
  try { New-Item -ItemType Directory -Force -Path $dir | Out-Null } catch { Die "cannot create $(Tildify $dir)" }
  if ($null -ne $node) {
    try { New-Item -ItemType Directory -Force -Path $BACKUP_DIR | Out-Null } catch { Die "cannot create $(Tildify $BACKUP_DIR)" }
    $backup = UniquePath $BACKUP_DIR 'settings.json' '.bak'
    if (-not (VerifiedCopy $target $backup)) { Die "could not back up $disp. Nothing changed." }
    if ($null -eq $node['env']) { $node['env'] = [System.Text.Json.Nodes.JsonObject]::new() }
    $node['env'][$ENV_VAR] = [System.Text.Json.Nodes.JsonValue]::Create('1')
  } else {
    $node = ParseNode "{`"env`": {`"$ENV_VAR`": `"1`"}}"
  }
  $tmp = MakeTmp $dir
  try { [IO.File]::WriteAllText($tmp, (NodeToText $node), (Utf8NoBom)); ReplaceFile $tmp $target }
  catch { CleanTmp; Die "could not replace $disp; it is unchanged." }
  $msg = 'Done.'; if ($backup) { $msg += " Previous file backed up to $(Tildify $backup)." }
  Say $msg
  Say "New Claude Code sessions get $ENV_VAR=1 from settings.json. Whether this applies early"
  Say 'enough to stop the very first flag fetch, and whether the Desktop app honors it, was not'
  Say "verified; `"$PROG check`" will show it (see step 3 above)."
}

function CmdOptout($rest) {
  $dry = $false; $apply = ''
  foreach ($a in $rest) {
    switch -CaseSensitive ([string]$a) {
      { $_ -ceq '-n' -or $_ -ceq '--dry-run' } { $dry = $true; break }
      '--apply-env' { $apply = 'settings'; break }
      '--apply-env=settings' { $apply = 'settings'; break }
      '--apply-env=user' { $apply = 'user'; break }
      '--apply-env=profile' { DieUsage 'optout: --apply-env=profile is for macOS/Linux shells; on Windows use --apply-env=user' }
      { $_.StartsWith('--apply-env=') } { DieUsage "optout: --apply-env takes 'settings' or 'user'" }
      { $_ -ceq '-y' -or $_ -ceq '--yes' } { $script:AssumeYes = $true; break }
      { $_ -ceq '-h' -or $_ -ceq '--help' } { Usage; exit 0 }
      default { DieUsage "optout: unknown option: $a" }
    }
  }
  if (-not (Test-Path -LiteralPath $CONFIG_FILE -PathType Leaf)) {
    Say "No Claude Code config file at $(Tildify $CONFIG_FILE); nothing to remove."
  } else {
    [void](ReadConfig $CONFIG_FILE)   # exits 2 if it is not a JSON object
    OptoutConfig $dry
  }
  EnvAdvice
  if ($apply -ne '') {
    if ($dry) { Say; Say 'Dry run: --apply-env was not applied.' }
    elseif ($apply -eq 'user') { ApplyEnvUser }
    else { ApplyEnvSettings }
  }
  exit 0
}

# ----------------------------------------------------------------- restore --

function CmdRestore($rest) {
  foreach ($a in $rest) {
    if ($a -ceq '-h' -or $a -ceq '--help') { Usage; exit 0 }
    DieUsage "restore: unknown option: $a"
  }
  $b = NewestBackup 'claude.json'
  if (-not $b) { Die "no backups in $(Tildify $BACKUP_DIR), so there is nothing to restore (optout makes one whenever it changes the file)." }
  try { $ok = (ParseJson ([IO.File]::ReadAllText($b))).RootElement.ValueKind -eq 'Object' } catch { $ok = $false }
  if (-not $ok) { Die "the newest backup, $(Tildify $b), is not valid JSON; not restoring it." }
  $target = ResolveLink $CONFIG_FILE
  $disp = Tildify $target
  if ((Test-Path -LiteralPath $target -PathType Leaf) -and (SameFile $b $target)) {
    Say "$disp already matches the newest backup ($(Tildify $b)). Nothing to do."
    exit 0
  }
  $snap = $null
  $tmp = MakeTmp (Split-Path -Parent $target)
  try { [IO.File]::WriteAllBytes($tmp, [IO.File]::ReadAllBytes($b)) } catch { CleanTmp; Die 'could not prepare the restored file. Nothing changed.' }
  if (Test-Path -LiteralPath $target -PathType Leaf) {
    $before = Sha $target
    $snap = UniquePath $BACKUP_DIR 'pre-restore.claude.json' '.bak'
    if (-not (VerifiedCopy $target $snap)) { CleanTmp; Die "could not save the current $disp before restoring. Nothing changed." }
    if ((Sha $target) -ne $before) { CleanTmp; Die "$disp changed while am-i-nerfed was working (is Claude Code running?). Nothing changed." }
  }
  try { ReplaceFile $tmp $target } catch { CleanTmp; Die "could not replace $disp; it is unchanged." }
  Say "Restored $disp from $(Tildify $b)."
  if ($snap) { Say "The file it replaced is saved as $(Tildify $snap)." }
  Say 'This rolls the whole file back to that backup, not only the assignment: anything Claude Code'
  Say 'changed in it since then (settings, project list, newer slots) is undone too.'
  Say "If you set $ENV_VAR=1 (by hand or with optout --apply-env), remove it from"
  Say "$(Tildify $SETTINGS_FILE) `"env`" or your user environment variables to let Claude Code refresh flags again."
  exit 0
}

# -------------------------------------------------------------- statusline --

function StatuslineRender {
  $out = 'exp:?'
  try {
    $inText = [Console]::In.ReadToEnd()
    if (Test-Path -LiteralPath $CONFIG_FILE -PathType Leaf) {
      $m = ''
      try {
        $in = FromJE (ParseJson $inText).RootElement
        if (IsObj $in) {
          if (IsObj $in['model']) { $m = ToJqString (Coalesce $in['model']['id'] '') } elseif ($in['model'] -is [string]) { $m = $in['model'] }
        }
      } catch { $m = '' }
      $cfg = ReadConfig $CONFIG_FILE
      $recs = AllRecs $cfg $false
      $cur = @($recs | Where-Object { $_.current -and $m -ne '' -and (NormModel $_.model) -eq (NormModel $m) })
      $ep = [string]$env:CLAUDE_CODE_ENTRYPOINT
      $pick = @($cur | Where-Object { $_.entrypoint -ceq $ep })
      if ($pick.Count -eq 0) { $pick = $cur }
      $asg = @($pick | Where-Object { $_.state -eq 'assigned' })
      if ($asg.Count -gt 0) { $out = 'exp:' + ((UniqueSorted @($asg | ForEach-Object { $_.id })) -join ',') }
      elseif (@($pick | Where-Object { $_.state -eq 'unassigned' }).Count -gt 0) { $out = 'exp:none' }
    }
  } catch { $out = 'exp:?' }
  Say $out
  exit 0
}

function CmdStatusline($rest) {
  $a = ''; if ($rest.Count -gt 0) { $a = [string]$rest[0] }
  switch -CaseSensitive ($a) {
    '--render' { StatuslineRender }
    { $_ -ceq '-h' -or $_ -ceq '--help' } { Usage; exit 0 }
    '' { }
    default { DieUsage "statusline: unknown option: $a" }
  }
  # Forward slashes work from cmd, PowerShell and Git Bash alike.
  $cmd = "pwsh -NoProfile -File `"$($PSCommandPath.Replace('\', '/'))`" statusline --render"
  Say 'Status line: shows exp:<id>, exp:none or exp:? for the model in use.'
  Say
  Say "Paste into $(Tildify $SETTINGS_FILE):"
  Say (ConvertTo-Json -InputObject ([ordered]@{ statusLine = [ordered]@{ type = 'command'; command = $cmd } }))
  Say
  Say 'Already have a status line? Run /statusline in Claude Code and ask it to append the output of:'
  Say "  $cmd"
  Say
  Say 'exp:<id>  the newest slot for this model carries an assignment (first 3 characters)'
  Say 'exp:none  the newest slot for this model carries none'
  Say 'exp:?     no slot for this model, or it could not be read'
  exit 0
}

# -------------------------------------------------------------------- main --

$cmd = 'check'
$rest = $ScriptArgs
if ($ScriptArgs.Count -gt 0) {
  $first = [string]$ScriptArgs[0]
  if (@('check', 'history', 'optout', 'restore', 'statusline') -ccontains $first) { $cmd = $first; $rest = @($ScriptArgs | Select-Object -Skip 1) }
  elseif (@('help', '-h', '--help') -ccontains $first) { Usage; exit 0 }
  elseif (@('version', '--version') -ccontains $first) { Say "am-i-nerfed $AMN_VERSION"; exit 0 }
  elseif ($first.StartsWith('-')) { }
  else { DieUsage "unknown command: $first" }
}
$rest = @($rest)
switch ($cmd) {
  'check' { CmdCheck $rest }
  'history' { CmdHistory $rest }
  'optout' { CmdOptout $rest }
  'restore' { CmdRestore $rest }
  'statusline' { CmdStatusline $rest }
}
