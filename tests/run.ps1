# Test runner for am-i-nerfed.ps1, the Windows port. Mirrors tests/run.sh.
#
# Uses only the synthetic fixtures in tests/fixtures. Every run gets its own
# temporary USERPROFILE and CLAUDE_CONFIG_DIR, so the real ~\.claude.json and
# ~\.claude are never read or written. --apply-env=user is only run in the
# modes that must refuse, and the test checks the real user variable stays put.
#
#   pwsh -File tests/run.ps1
#   $env:PWSH_UNDER_TEST = 'C:\path\pwsh.exe'; pwsh -File tests/run.ps1
#   $env:VERBOSE = 1; pwsh -File tests/run.ps1     also list passing checks
#
# Exit status: 0 all passed, 1 failures.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$Root = Split-Path -Parent $PSScriptRoot
$Script = Join-Path $Root 'am-i-nerfed.ps1'
$Fix = Join-Path $Root 'tests\fixtures'
$Pwsh = $env:PWSH_UNDER_TEST
if (-not $Pwsh) { $Pwsh = (Get-Process -Id $PID).Path }
$Work = Join-Path ([IO.Path]::GetTempPath()) ('amn-tests.' + [IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $Work | Out-Null
$EnvVar = 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC'
$UserVarBefore = [Environment]::GetEnvironmentVariable($EnvVar, 'User')

$script:Pass = 0; $script:Fail = 0; $script:Group = ''
$Log = [Text.StringBuilder]::new()       # every output except --full runs
$FullLog = [Text.StringBuilder]::new()
$TokDba = 'dba7c1f0e2d94b3a8c6e5f4d3c2b1a09-tokentail-01'

# ------------------------------------------------------------------ helpers --

function TGroup([string]$g) { $script:Group = $g; if ($env:VERBOSE) { "`n## $g" | Out-Host } }
function Pass([string]$d) { $script:Pass++; if ($env:VERBOSE) { "ok    $d" | Out-Host } }
function Fail([string]$d, [string]$why = '') {
  $script:Fail++
  "FAIL  [$($script:Group)] $d" | Out-Host
  if ($why) { "      $why" | Out-Host }
}

# Setup FIXTURE: fresh temp config dir (copy of the fixture) and temp home.
function Setup([string]$fixture) {
  $script:Case = Join-Path $Work ([IO.Path]::GetRandomFileName())
  $script:Cfg = Join-Path $Case 'config'
  $script:HomeDir = Join-Path $Case 'home'
  New-Item -ItemType Directory -Path $Cfg, $HomeDir | Out-Null
  if ($fixture) { Copy-Item -Path (Join-Path $Fix "$fixture\*") -Destination $Cfg -Recurse -Force }
  Get-ChildItem -LiteralPath $Cfg -Filter '.gitkeep' -Force | Remove-Item -Force
  Get-ChildItem -LiteralPath $Cfg -Filter '.claude.json' -Force | ForEach-Object { $_.Attributes = 'Normal' }   # hidden on checkout
  $script:ConfigDir = $Cfg
  $script:Entrypoint = $null
  $script:Stdin = ''
}

# Run a program with the test environment; sets $Out, $Err, $RC.
# $argv is a list of arguments, or one string passed verbatim (for cmd.exe /c).
function RunProc([string]$file, $argv) {
  $psi = [Diagnostics.ProcessStartInfo]::new($file)
  if ($argv -is [string]) { $psi.Arguments = $argv } else { foreach ($a in $argv) { $psi.ArgumentList.Add($a) } }
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.Environment['USERPROFILE'] = $HomeDir
  $psi.Environment['HOME'] = $HomeDir
  if ($ConfigDir) { $psi.Environment['CLAUDE_CONFIG_DIR'] = $ConfigDir } else { [void]$psi.Environment.Remove('CLAUDE_CONFIG_DIR') }
  if ($Entrypoint) { $psi.Environment['CLAUDE_CODE_ENTRYPOINT'] = $Entrypoint } else { [void]$psi.Environment.Remove('CLAUDE_CODE_ENTRYPOINT') }
  [void]$psi.Environment.Remove($EnvVar)
  $p = [Diagnostics.Process]::Start($psi)
  $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
  $p.StandardInput.Write($Stdin); $p.StandardInput.Close()
  $p.WaitForExit()
  $script:Out = $o.Result; $script:Err = $e.Result; $script:RC = $p.ExitCode
}

function Amn {
  $argv = @($args | ForEach-Object { [string]$_ })
  RunProc $Pwsh (@('-NoProfile', '-NonInteractive', '-File', $Script) + $argv)
  $log = $Log; if ($argv -contains '--full') { $log = $FullLog }
  [void]$log.AppendLine("`n`$ am-i-nerfed $($argv -join ' ')  [$($script:Group)]").Append($Out).Append($Err)
}

function Lines([string]$s) { return , @($s -split "`r?`n" | ForEach-Object { $_.TrimEnd(' ') }) }
function T_rc($want, $d) { if ($RC -eq $want) { Pass $d } else { Fail $d "expected exit $want, got $RC; stderr: $($Err.Substring(0, [Math]::Min(300, $Err.Length)))" } }
function T_has($s, $d) { if ($Out.Contains($s)) { Pass $d } else { Fail $d "stdout lacks: $s" } }
function T_err($s, $d) { if ($Err.Contains($s)) { Pass $d } else { Fail $d "stderr lacks: $s" } }
function T_lacks($s, $d) { if ($Out.Contains($s) -or $Err.Contains($s)) { Fail $d "output contains: $s" } else { Pass $d } }
function T_line($s, $d) { if ((Lines $Out) -ccontains $s) { Pass $d } else { Fail $d "no line: $s" } }
function T_json([scriptblock]$cond, $d) {
  try { $j = $Out | ConvertFrom-Json -Depth 100; $ok = [bool](& $cond $j) } catch { $ok = $false }
  if ($ok) { Pass $d } else { Fail $d "false: $cond" }
}
function T_ok($d, [scriptblock]$cond) { try { $ok = [bool](& $cond) } catch { $ok = $false }; if ($ok) { Pass $d } else { Fail $d } }
function SameFile($a, $b) { return (Get-FileHash -LiteralPath $a).Hash -eq (Get-FileHash -LiteralPath $b).Hash }
function Backups($pattern) { $d = Join-Path $Cfg 'am-i-nerfed\backups'; if (-not (Test-Path $d)) { return 0 }; return @(Get-ChildItem -LiteralPath $d -File -Force -Filter $pattern).Count }
function ReadJson($p) { return (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json -Depth 100) }

# The expected optout result, computed independently of the script: the same
# document with data.atis and data.experimentKey removed, compared as compact JSON.
function StripExpected($p) {
  $j = ReadJson $p
  foreach ($s in $j.clientDataCacheSlots.PSObject.Properties) {
    $d = $s.Value.data
    if ($d -is [pscustomobject]) { $d.PSObject.Properties.Remove('atis'); $d.PSObject.Properties.Remove('experimentKey') }
  }
  return (ConvertTo-Json -InputObject $j -Depth 100 -Compress)
}
function Canon($p) { return (ConvertTo-Json -InputObject (ReadJson $p) -Depth 100 -Compress) }

$ConfigFile = { Join-Path $Cfg '.claude.json' }

# --------------------------------------------------------------- check: CLI --

TGroup 'check clean'
Setup clean
Amn check
T_rc 0 'clean exits 0'
T_line 'Overall: CLEAN (exit 0)' 'overall verdict line'
T_has 'claude-opus-5-5   CLEAN as of 2026-10-30 10:00:00 UTC (state after that time unknown)' 'opus-5-5 clean as of its newest slot'
T_has 'claude-fable-5-1  CLEAN as of 2026-10-25 09:30:00 UTC' 'fable-5-1 clean'
T_has 'claude-opus-4-8   CLEAN as of 2026-09-15 07:45:00 UTC' 'opus-4-8 clean'
T_has 'superseded' 'older slot marked superseded'
T_lacks 'ENROLLED' 'no ENROLLED anywhere'
Amn
T_rc 0 'check is the default command'
Amn --json
T_rc 0 '--json alone runs check'
T_json { param($j) $j.status -eq 'clean' -and $j.exit_code -eq 0 -and @($j.models).Count -eq 3 } 'json status clean'
T_json { param($j) @($j.slots | Where-Object { $_.state -ne 'unassigned' }).Count -eq 0 } 'json: every slot unassigned'
T_json { param($j) @($j.slots | Where-Object { $_.PSObject.Properties.Name -contains 'atis' }).Count -eq 0 } 'json: no atis field without --full'

TGroup 'check enrolled'
Setup enrolled
Amn check
T_rc 1 'enrolled exits 1'
T_has 'claude-opus-5-5   ENROLLED (ID dba via cli, experimentKey exp_fixture_dba)' 'opus-5-5 enrolled dba'
T_has 'claude-fable-5-1  ENROLLED (ID 34e via claude-desktop, experimentKey exp_fixture_34e)' 'fable enrolled 34e'
T_has 'claude-opus-4-8   CLEAN as of 2026-09-15 07:45:00 UTC' 'opus-4-8 still clean'
T_line 'Overall: ENROLLED (exit 1)' 'overall enrolled'
T_lacks 'tokentail' 'whole token hidden by default'
Amn check --json
T_rc 1 'json exit 1'
T_json { param($j) $j.status -eq 'enrolled' -and ((@($j.models | Where-Object { $_.verdict -eq 'ENROLLED' } | ForEach-Object { $_.ids }) | Sort-Object) -join ',') -eq '34e,dba' } 'json ids'
T_lacks 'tokentail' 'json hides whole token'
Amn check --full
T_rc 1 '--full exit 1'
T_has $TokDba '--full shows the whole token'
T_has 'TOKEN' '--full header'
Amn check --json --full
T_json { param($j) $j.status -eq 'enrolled' } 'json --full parses'
T_json { param($j) @($j.slots | Where-Object { $_.PSObject.Properties.Name -contains 'atis' }).Count -eq 2 } 'json --full carries 2 tokens'

TGroup 'check mixed entrypoints'
Setup mixed
Amn check
T_rc 1 'mixed exits 1'
T_has 'claude-opus-5-5   ENROLLED (ID 763 via cli, experimentKey exp_fixture_763)' 'cli slot enrolled, desktop clean -> enrolled via cli only'
T_lacks 'via claude-desktop, experimentKey exp_fixture_763' 'desktop not reported enrolled'
T_has 'claude-fable-5-1  CLEAN as of 2026-10-30 10:00:00 UTC' 'superseded assignment does not count'
T_has 'an older, superseded claude-desktop slot from 2026-10-20 08:00:00 UTC carried ID eab' 'superseded assignment noted'
T_has 'claude-opus-4-8   CLEAN as of 2026-10-25 09:30:00 UTC' 'other-org assignment ignored'
T_has 'other org, ignored' 'other-org slot labeled'
T_has 'claude-haiku-5-5  INCONCLUSIVE (no slot with readable assignment data)' 'unreadable slot -> inconclusive'
Amn check --model claude-fable-5-1
T_rc 0 '--model clean model exits 0'
T_lacks 'claude-opus-5-5' '--model filters the table'
Amn check --model opus-5-5
T_rc 1 '--model accepts a name without claude- prefix'
Amn check --model 'claude-opus-5-5[1m]'
T_rc 1 '--model ignores a [1m] suffix'
Amn check --model claude-haiku-5-5
T_rc 3 '--model unreadable exits 3'
Amn check --model claude-nonexistent-9
T_rc 3 '--model without slot exits 3'
T_has 'claude-nonexistent-9  INCONCLUSIVE (no slot for this model)' 'no slot -> INCONCLUSIVE (no slot)'
Amn check --json --model claude-nonexistent-9
T_json { param($j) $j.status -eq 'inconclusive' -and $j.models[0].reason -eq 'no slot for this model' } 'json no-slot reason'

TGroup 'check cachedExperimentData'
Setup experiments
Amn check
T_rc 0 'named experiments do not change the verdict'
T_line 'Not checked: 3 named feature-flag experiment(s) in cachedExperimentData (ordinary flags, not x-cc-atis).' 'count line printed'
T_ok 'count line comes right after the Overall line' { $l = Lines $Out; $i = [Array]::IndexOf($l, 'Overall: CLEAN (exit 0)'); $i -ge 0 -and $l[$i + 1].StartsWith('Not checked: 3 ') }
T_lacks 'fixture_named_exp' 'no experiment name printed'
T_lacks 'fixture-exp-id' 'no experiment ID printed'
T_lacks 'fixture-exp-value-marker' 'no experiment value printed'
Amn check --json
T_json { param($j) $j.cached_experiment_data_count -eq 3 -and $j.status -eq 'clean' } 'json count'
T_lacks 'fixture_named_exp' 'json: no experiment name'
T_lacks 'fixture-exp-value-marker' 'json: no experiment value'
$j = ReadJson (& $ConfigFile); $j.cachedExperimentData = [pscustomobject]@{}; ConvertTo-Json $j -Depth 100 | Set-Content -LiteralPath (& $ConfigFile)
Amn check
T_lacks 'Not checked:' 'empty cachedExperimentData: no count line'
Amn check --json
T_json { param($j) $j.cached_experiment_data_count -eq 0 } 'empty cachedExperimentData: json count 0'
Setup clean
Amn check
T_lacks 'Not checked:' 'absent cachedExperimentData: no count line'
Amn check --json
T_json { param($j) $null -eq $j.cached_experiment_data_count } 'absent cachedExperimentData: json null'

TGroup 'check missing / no slots / bad input'
Setup missing
Amn check
T_rc 3 'missing config exits 3'
T_has 'No Claude Code config file here' 'missing explained'
T_line 'Overall: INCONCLUSIVE (exit 3)' 'overall inconclusive'
Amn check --json
T_rc 3 'missing json exits 3'
T_json { param($j) $j.config_present -eq $false -and $j.status -eq 'inconclusive' -and $j.slot_count -eq 0 } 'missing json'
Setup noslots
Amn check
T_rc 3 'no slots exits 3'
T_has 'No experiment-cache slots' 'no slots explained'
Amn check --json
T_json { param($j) $j.config_present -eq $true -and $j.status -eq 'inconclusive' } 'no slots json'
Setup clean
Set-Content -LiteralPath (& $ConfigFile) -Value '{"clientDataCacheSlots": {' -NoNewline
Amn check
T_rc 2 'invalid JSON exits 2'
T_err 'not a valid JSON object' 'invalid JSON explained'
Amn check --bogus
T_rc 2 'unknown option exits 2'
Amn frobnicate
T_rc 2 'unknown command exits 2'
Amn --help
T_rc 0 '--help exits 0'
T_has 'statusline' '--help lists commands'

TGroup 'Windows PowerShell 5.1'
$wps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
if ($env:WINDIR -and (Test-Path -LiteralPath $wps)) {
  Setup clean
  RunProc $wps @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Script, 'check')
  T_rc 2 'Windows PowerShell 5.1 exits 2'
  T_err 'PowerShell 7.2 or newer is required' 'says which PowerShell it needs'
} else {
  'skip  Windows PowerShell 5.1 not installed' | Out-Host
}

TGroup 'config location'
Setup enrolled
# Decoys in the home directory must be ignored while CLAUDE_CONFIG_DIR is set.
New-Item -ItemType Directory -Path (Join-Path $HomeDir '.claude\projects\-decoy') | Out-Null
(Get-Content -LiteralPath (Join-Path $Fix 'enrolled\.claude.json') -Raw).Replace('dba7c1f0', '9de7c1f0') | Set-Content -LiteralPath (Join-Path $HomeDir '.claude.json')
'{"type":"atis-latch","atis":"9dedecoy","sessionId":"decoy"}' | Set-Content -LiteralPath (Join-Path $HomeDir '.claude\projects\-decoy\decoy.jsonl')
Amn check
T_has 'ID dba' 'reads CLAUDE_CONFIG_DIR\.claude.json'
T_lacks '9de' 'ignores ~\.claude.json when CLAUDE_CONFIG_DIR is set'
Amn history
T_lacks '9de' 'ignores ~\.claude\projects when CLAUDE_CONFIG_DIR is set'
$script:ConfigDir = $null
Copy-Item -LiteralPath (Join-Path $Fix 'enrolled\.claude.json') -Destination (Join-Path $HomeDir '.claude.json') -Force
Amn check
T_rc 1 'without CLAUDE_CONFIG_DIR reads %USERPROFILE%\.claude.json'
T_has 'ID dba' 'default location finds the assignment'
T_has '~\.claude.json' 'home directory shown as ~'
Amn history
T_has '9de' 'without CLAUDE_CONFIG_DIR reads %USERPROFILE%\.claude\projects'

# ----------------------------------------------------------------- history --

TGroup 'history'
Setup history
Amn history
T_rc 0 'history exits 0'
T_has 'Scanned 4 transcript file(s); 3 contain atis-latch entries.' 'file counts (subagent file has none)'
T_line '2026-10-20  none  1         2' 'empty atis tallied as none'
T_line '2026-10-21  dba   1         1' 'entry before midnight dated by preceding timestamp'
T_line '2026-10-22  dba   1         1' 'entry after midnight dated to next day'
T_line '2026-10-23  34e   1         2' 'entry before any timestamp uses the first timestamp'
T_has 'Sessions that recorded an experiment ID: 2 of 3.' 'session summary'
T_has 'IDs seen: 34e (1 session(s), 2026-10-23 to 2026-10-23); dba (1 session(s), 2026-10-21 to 2026-10-22)' 'IDs summary'
T_lacks 'eab' 'text mentions of atis-latch are not counted'
T_lacks 'tokentail' 'whole tokens hidden'
Amn history --json
T_rc 0 'history json exits 0'
T_json { param($j) $j.files_scanned -eq 4 -and $j.files_with_records -eq 3 -and $j.sessions -eq 3 -and $j.sessions_with_id -eq 2 } 'history json counts'
T_json { param($j) (@($j.by_date | ForEach-Object { "$($_.date)/$($_.id)/$($_.sessions)/$($_.records)" }) -join ' ') -eq '2026-10-20/none/1/2 2026-10-21/dba/1/1 2026-10-22/dba/1/1 2026-10-23/34e/1/2' } 'history json rows'
T_lacks 'tokentail' 'history json hides tokens'
Amn history --full
T_has $TokDba 'history --full shows whole tokens'

TGroup 'history without the field'
Setup nofield
Amn history
T_rc 0 'no field exits 0'
T_has 'No experiment identifiers found. None of the 1 transcript file(s) contains an' 'says so plainly'
T_lacks '763' 'text mentions of atis are not counted'
Amn history --json
T_json { param($j) $j.files_with_records -eq 0 -and @($j.by_date).Count -eq 0 -and $j.note -is [string] } 'no-field json'
Setup clean
Amn history
T_rc 0 'no transcripts dir exits 0'
T_has 'No session transcripts' 'no transcripts explained'
Amn history --json
T_json { param($j) $j.files_scanned -eq 0 } 'no transcripts json'

# ------------------------------------------------------------------ optout --

TGroup 'optout'
Setup enrolled
$orig = Join-Path $Case 'original.json'
Copy-Item -LiteralPath (& $ConfigFile) -Destination $orig
Amn optout --dry-run
T_rc 0 'dry run exits 0'
T_has 'Dry run. Would remove' 'dry run says so'
T_ok 'dry run leaves the file alone' { SameFile $orig (& $ConfigFile) }
T_ok 'dry run makes no backup' { (Backups 'claude.json.*.bak') -eq 0 }
Amn optout
T_rc 0 'optout exits 0'
T_has 'Removing data.atis and data.experimentKey from 2 slot(s)' 'optout lists what it removes'
T_has "`$env:$EnvVar = '1'" 'prints the env var line'
T_has 'DISABLE_AUTOUPDATER, DISABLE_BUG_COMMAND,' "states Anthropic's documented equivalence"
T_has 'Automatic updates' 'warns about auto-updates'
T_has 'Users report that it also stops every remote feature-flag update' 'flag freeze worded as a user report'
T_has 're-enrolls you, and that starting Claude Code with this variable set blocks' 're-enrollment block worded as a user report'
T_has 'not verified by this project' 'hedge present'
T_ok 'exactly one backup' { (Backups 'claude.json.*.bak') -eq 1 }
$bk = @(Get-ChildItem -LiteralPath (Join-Path $Cfg 'am-i-nerfed\backups') -Filter 'claude.json.*.bak')[0].FullName
T_ok 'backup equals the original byte for byte' { SameFile $orig $bk }
T_ok 'only atis/experimentKey removed; everything else identical' { (StripExpected $orig) -ceq (Canon (& $ConfigFile)) }
T_ok 'no atis or experimentKey left' { -not ((Get-Content -LiteralPath (& $ConfigFile) -Raw) -match '"(atis|experimentKey)"') }
T_ok 'other flags in the same slot kept' { (ReadJson (& $ConfigFile)).clientDataCacheSlots.'k2b-000000000000e001'.data.fixture_date_flag -eq '2026-10-01' }
T_ok 'oauthAccount untouched' { (ConvertTo-Json (ReadJson (& $ConfigFile)).oauthAccount) -eq (ConvertTo-Json (ReadJson $orig).oauthAccount) }
T_ok 'file keeps 2-space indent and LF line ends' { $t = Get-Content -LiteralPath (& $ConfigFile) -Raw; $t.StartsWith("{`n  `"") -and -not $t.Contains("`r") }
Amn check
T_rc 0 'check after optout is clean'
$afterFirst = Join-Path $Case 'after-first.json'
Copy-Item -LiteralPath (& $ConfigFile) -Destination $afterFirst
Amn optout
T_rc 0 'second optout exits 0'
T_has 'Already clean' 'second optout is a no-op'
T_ok 'second optout makes no new backup' { (Backups 'claude.json.*.bak') -eq 1 }
T_ok 'second optout leaves the file alone' { SameFile $afterFirst (& $ConfigFile) }
T_ok 'no temp files left behind' { @(Get-ChildItem -LiteralPath $Cfg -Recurse -Force -Filter '.am-i-nerfed.*').Count -eq 0 }

TGroup 'optout mixed + symlink'
Setup mixed
$real = Join-Path $Case 'real-claude.json'
Move-Item -LiteralPath (& $ConfigFile) -Destination $real
$linked = $true
try { New-Item -ItemType SymbolicLink -Path (& $ConfigFile) -Target $real -ErrorAction Stop | Out-Null } catch { $linked = $false }
if (-not $linked) {
  'skip  symlink part (creating symlinks needs Developer Mode or admin); running on a plain file' | Out-Host
  Move-Item -LiteralPath $real -Destination (& $ConfigFile); $real = & $ConfigFile
}
Copy-Item -LiteralPath $real -Destination (Join-Path $Case 'original.json')
Amn optout
T_rc 0 'optout (through a symlink if available) exits 0'
T_has 'from 3 slot(s)' 'removes from every slot, other org included'
if ($linked) { T_ok 'symlink kept' { (Get-Item -LiteralPath (& $ConfigFile)).LinkType -eq 'SymbolicLink' } }
T_ok 'target rewritten correctly' { (StripExpected (Join-Path $Case 'original.json')) -ceq (Canon $real) }
T_ok 'data:null slot untouched' { $null -eq (ReadJson $real).clientDataCacheSlots.'k3c-000000000000m007'.data }
Amn check
T_rc 3 'after optout: clean except the unreadable slot (exit 3)'

TGroup 'optout missing / noslots'
Setup missing
Amn optout
T_rc 0 'optout with no config exits 0'
T_has 'nothing to remove' 'explains'
T_ok 'creates no config file' { -not (Test-Path -LiteralPath (& $ConfigFile)) }
Setup noslots
Copy-Item -LiteralPath (& $ConfigFile) -Destination (Join-Path $Case 'original.json')
Amn optout
T_rc 0 'optout with no slots exits 0'
T_has 'Already clean' 'no slots: already clean'
T_ok 'no slots: unchanged' { SameFile (Join-Path $Case 'original.json') (& $ConfigFile) }

TGroup 'optout big integers'
Setup enrolled
(Get-Content -LiteralPath (Join-Path $Fix 'enrolled\.claude.json') -Raw).Replace('"bigNumberProbe": 1234567', '"bigNumberProbe": 12345678901234567890123') |
  Set-Content -LiteralPath (& $ConfigFile) -NoNewline
Amn optout
T_rc 0 'optout with a big integer'
T_ok 'big integer literal preserved' { (Get-Content -LiteralPath (& $ConfigFile) -Raw).Contains('12345678901234567890123') }

TGroup 'optout --apply-env'
Setup enrolled
Amn optout --apply-env
T_rc 0 'apply-env without --yes on a non-tty exits 0'
T_has 'Not applied' 'refuses to edit without --yes when not interactive'
T_ok 'settings.json not created' { -not (Test-Path -LiteralPath (Join-Path $Cfg 'settings.json')) }
Amn optout --apply-env --yes
T_has "+  `"$EnvVar`": `"1`"" 'shows the exact edit'
T_ok 'settings.json created with the env var' { (ReadJson (Join-Path $Cfg 'settings.json')).env.$EnvVar -eq '1' }
Amn optout --apply-env --yes
T_has 'Already set' 'settings edit is idempotent'
Setup clean
$settings = Join-Path $Cfg 'settings.json'
"{`n  `"model`": `"opus`",`n  `"env`": {`"OTHER_VAR`": `"keep-me`", `"$EnvVar`": `"0`"},`n  `"permissions`": {`"allow`": [`"Bash(ls:*)`"]}`n}`n" | Set-Content -LiteralPath $settings -NoNewline
Amn optout --apply-env=settings --yes
T_rc 0 'apply-env=settings exits 0'
T_has "-  `"$EnvVar`": `"0`"" 'shows the old value being replaced'
T_ok 'env var now 1' { (ReadJson $settings).env.$EnvVar -eq '1' }
T_ok 'other settings kept' { $s = ReadJson $settings; $s.env.OTHER_VAR -eq 'keep-me' -and $s.model -eq 'opus' -and (@($s.permissions.allow) -join ',') -eq 'Bash(ls:*)' }
T_ok 'settings backup made' { (Backups 'settings.json.*.bak') -eq 1 }
T_lacks 'keep-me' 'other env values are never printed'
Setup clean
Amn optout --apply-env=user
T_rc 0 'apply-env=user without --yes on a non-tty exits 0'
if ($UserVarBefore -ceq '1') {
  T_has 'Already set as a user environment variable' 'user variable already 1 on this machine: says so'
} else {
  T_has "+ $EnvVar=1" 'shows the user variable edit'
  T_has 'Not applied' 'refuses to set the user variable without --yes when not interactive'
}
Amn optout --apply-env=profile
T_rc 2 '--apply-env=profile is rejected on Windows'
T_err '--apply-env=user' 'points to --apply-env=user'
Amn optout --dry-run --apply-env --yes
T_has 'Dry run: --apply-env was not applied.' 'dry run does not apply env'
T_ok 'dry run: no settings.json' { -not (Test-Path -LiteralPath (Join-Path $Cfg 'settings.json')) }
Amn optout --dry-run --apply-env=user --yes
T_has 'Dry run: --apply-env was not applied.' 'dry run does not set the user variable'
T_ok 'the real user environment variable was never changed' { [Environment]::GetEnvironmentVariable($EnvVar, 'User') -ceq $UserVarBefore }
Setup clean
"{ // comment`n `"env`": {} }`n" | Set-Content -LiteralPath (Join-Path $Cfg 'settings.json') -NoNewline
Amn optout --apply-env --yes
T_rc 2 'refuses to edit a settings.json it cannot parse'

# ----------------------------------------------------------------- restore --

TGroup 'restore'
Setup clean
Amn restore
T_rc 2 'restore without backups exits 2'
T_err 'nothing to restore' 'explains'
Setup enrolled
Copy-Item -LiteralPath (& $ConfigFile) -Destination (Join-Path $Case 'original.json')
Amn optout
Amn check
T_rc 0 'clean after optout'
Amn restore
T_rc 0 'restore exits 0'
T_ok 'restore brings back the original bytes' { SameFile (Join-Path $Case 'original.json') (& $ConfigFile) }
T_ok 'pre-restore snapshot saved' { (Backups 'pre-restore.claude.json.*.bak') -eq 1 }
T_has 'rolls the whole file back' 'warns that the whole file is rolled back'
Amn check
T_rc 1 'enrolled again after restore'
Amn restore
T_has 'already matches the newest backup' 'second restore is a no-op'
T_ok 'no second snapshot' { (Backups 'pre-restore.claude.json.*.bak') -eq 1 }
# A refresh written after an optout is flagged by check.
Setup enrolled
Amn optout
$j = ReadJson (& $ConfigFile)
$j.clientDataCacheSlots | Add-Member -NotePropertyName 'k9z-00000000000new01' -NotePropertyValue ([pscustomobject]@{ model = 'claude-opus-5-5'; entrypoint = 'cli'; at = 4102444800000; data = [pscustomobject]@{} })
ConvertTo-Json $j -Depth 100 | Set-Content -LiteralPath (& $ConfigFile)
Amn check
T_has 'slots were written after your last optout' 'check flags flag refreshes after optout'
Amn check --json
T_json { param($j) $j.slots_written_after_last_optout -eq 1 -and $null -ne $j.last_optout } 'json flags refresh after optout'
Amn restore
Amn check
T_lacks 'slots were written after your last optout' 'no refresh warning after a restore'

# -------------------------------------------------------------- statusline --

TGroup 'statusline'
Setup enrolled
$script:Stdin = '{"model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"}}'
Amn statusline --render
T_line 'exp:dba' 'enrolled model renders exp:dba'
$script:Stdin = '{"model":{"id":"claude-opus-5-5[1m]"}}'
Amn statusline --render
T_line 'exp:dba' '[1m] suffix ignored'
$script:Stdin = '{"model":{"id":"claude-opus-4-8"}}'
Amn statusline --render
T_line 'exp:none' 'clean model renders exp:none'
$script:Stdin = '{"model":{"id":"claude-unknown-1"}}'
Amn statusline --render
T_line 'exp:?' 'model without slot renders exp:?'
$script:Stdin = 'not json'
Amn statusline --render
T_rc 0 'garbage stdin exits 0'
T_line 'exp:?' 'garbage stdin renders exp:?'
Setup mixed
$script:Stdin = '{"model":{"id":"claude-opus-5-5"}}'
$script:Entrypoint = 'cli'
Amn statusline --render
T_line 'exp:763' 'entrypoint cli picks the cli slot'
$script:Entrypoint = 'claude-desktop'
Amn statusline --render
T_line 'exp:none' 'entrypoint claude-desktop picks the desktop slot'
Setup missing
$script:Stdin = '{"model":{"id":"claude-opus-5-5"}}'
Amn statusline --render
T_line 'exp:?' 'missing config renders exp:?'

TGroup 'statusline snippet'
Setup enrolled
Amn statusline
T_rc 0 'snippet exits 0'
T_has '"statusLine"' 'snippet has a statusLine block'
T_has 'statusline --render' 'the snippet calls the script'
$l = Lines $Out; $i = 0; while ($i -lt $l.Count -and -not $l[$i].StartsWith('Paste into')) { $i++ }
$block = @(); $i++; while ($i -lt $l.Count -and $l[$i] -ne '') { $block += $l[$i]; $i++ }
$cmd = $null
try { $cmd = ($block -join "`n" | ConvertFrom-Json).statusLine.command } catch { }
T_ok 'snippet is valid JSON' { $cmd -is [string] }
if ($cmd) {
  $script:Stdin = '{"model":{"id":"claude-opus-5-5"}}'
  RunProc (Join-Path $env:WINDIR 'System32\cmd.exe') "/d /s /c `"$cmd`""
  T_ok "snippet command renders exp:dba from cmd.exe (got: $($Out.Trim()))" { $Out.Trim() -ceq 'exp:dba' }
}

TGroup 'README one-liner'
Setup enrolled
Copy-Item -LiteralPath (& $ConfigFile) -Destination (Join-Path $HomeDir '.claude.json')   # the one-liner reads %USERPROFILE%
$line = @(Get-Content -LiteralPath (Join-Path $Root 'README.md') | Where-Object { $_.StartsWith('(Get-Content "$env:USERPROFILE') })
if ($line.Count -eq 0) { Fail 'README PowerShell one-liner found' } else {
  RunProc $Pwsh @('-NoProfile', '-NonInteractive', '-Command', $line[0])
  T_line 'claude-opus-5-5 | cli | 2026-11-01 12:00:00Z | dba | exp_fixture_dba' 'one-liner lists the dba slot'
  T_line 'claude-opus-4-8 | cli | 2026-09-15 07:45:00Z | none | -' 'one-liner shows none for a clean slot'
  T_lacks 'tokentail' 'one-liner prints no whole token'
  T_lacks 'sentinel' 'one-liner prints no account values'
}

# ------------------------------------------------------------- static/global --

TGroup 'static checks'
$src = Get-Content -LiteralPath $Script -Raw
T_ok 'script has no network calls' { -not ($src -match '(?i)Invoke-WebRequest|Invoke-RestMethod|WebClient|HttpClient|TcpClient|Net\.Sockets|Start-BitsTransfer|\bcurl\b|\bwget\b') }
T_ok 'script is ASCII only (Windows PowerShell 5.1 reads BOM-less files as ANSI)' { -not ($src -match '[^\x00-\x7F]') }
$errs = $null; [void][Management.Automation.Language.Parser]::ParseFile($Script, [ref]$null, [ref]$errs)
T_ok 'script parses' { $errs.Count -eq 0 }

TGroup 'no secrets in output'
$all = $Log.ToString() + $FullLog.ToString()
if ($all -match '(?i)sentinel') { Fail 'no oauthAccount / userID / API key value ever printed' } else { Pass 'no oauthAccount / userID / API key value ever printed' }
if ($Log.ToString().Contains('tokentail')) { Fail 'whole tokens appear only in --full runs' } else { Pass 'whole tokens appear only in --full runs' }

Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
"`n$($script:Pass) passed, $($script:Fail) failed  (PowerShell $($PSVersionTable.PSVersion))" | Out-Host
if ($script:Fail -ne 0) { exit 1 }
exit 0
