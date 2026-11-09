# am-i-nerfed

Checks whether your Claude Code account is enrolled in a server-side experiment, and lets you opt out.

Claude Code caches an experiment assignment in `~/.claude.json` and sends it to Anthropic on every request as an `x-cc-atis` header. Under some assignments the same model behaves differently: more tool calls per reply, longer shell commands, less narration, and possibly faster usage burn. Measurements show the behaviour changes. They do not show the output got worse. Decide for yourself.

Unofficial. Reads undocumented internals. May break on any Claude Code release.

## 60-second check (no install)

Requires `jq`. Paste into a terminal:

```sh
jq -r '(.clientDataCacheSlots // {}) | to_entries[] | "\(.value.model // "-") | \(.value.entrypoint // "-") | \(((.value.at // 0)/1000|floor)|todate) | \(.value.data.atis[0:3] // "none") | \(.value.data.experimentKey // "-")"' ~/.claude.json
```

One line per cached slot: `model | entrypoint | slot time (UTC) | experiment ID | experiment key`.
`none` on every line means not enrolled as of the newest slot time. Empty output means no cached slot — inconclusive.

On Windows, without jq, in PowerShell 7:

```powershell
(Get-Content "$env:USERPROFILE\.claude.json" -Raw | ConvertFrom-Json -AsHashtable).clientDataCacheSlots.Values | ForEach-Object { '{0} | {1} | {2:u} | {3} | {4}' -f $_.model, $_.entrypoint, [DateTimeOffset]::FromUnixTimeMilliseconds($_.at).UtcDateTime, $(if ($_.data.atis) { $_.data.atis.Substring(0, 3) } else { 'none' }), $(if ($_.data.experimentKey) { $_.data.experimentKey } else { '-' }) }
```

## Install

```sh
git clone https://github.com/electricshadows44/am-i-nerfed.git
cd am-i-nerfed
./am-i-nerfed.sh check
```

Or as a Claude Code plugin: install this repo, then run `/am-i-nerfed` inside any session. The command list shows it as `/am-i-nerfed:am-i-nerfed`; both forms work (verified on Claude Code 2.1.319).

Requires bash 3.2+ and `jq` (`brew install jq` / `apt install jq`; jq 1.7+ needed for `optout`). macOS, Linux, WSL.

### Windows

`am-i-nerfed.ps1` is a native PowerShell port: same commands, same output, same exit codes, no jq. It needs PowerShell 7.2+ (`winget install Microsoft.PowerShell`); Windows PowerShell 5.1 is refused with a message.

```powershell
git clone https://github.com/electricshadows44/am-i-nerfed.git
cd am-i-nerfed
pwsh -File .\am-i-nerfed.ps1 check
```

It reads `%USERPROFILE%\.claude.json` and `%USERPROFILE%\.claude\` (or `CLAUDE_CONFIG_DIR`), like Claude Code on Windows. Differences from the bash script: `optout --apply-env=user` sets the variable as a Windows user environment variable (seen by the Desktop app and every new terminal) instead of `--apply-env=profile`, and `statusline` prints one snippet that runs the script with `pwsh`. The plugin skill uses it automatically on Windows.

## Commands

| Command | What it does | Changes anything? |
|---|---|---|
| `check` | Lists cached slots, gives a verdict per model. Default. `--json`, `--model ID`. | No |
| `history` | Tallies experiment IDs recorded in your session transcripts by date. Transcripts are kept about 30 days. | No |
| `optout` | Backs up `~/.claude.json`, removes the assignment keys, prints the env var that blocks re-enrollment. `--dry-run` shows the plan. | Yes (backup first) |
| `optout --apply-env` | Also sets the env var in `~/.claude/settings.json`, after showing the edit. `--apply-env=profile` appends to your shell profile instead (Windows: `--apply-env=user` sets a user environment variable). | Yes |
| `restore` | Reverts the newest backup (whole file, not only the assignment). | Yes |
| `statusline` | Prints a `/statusline` snippet showing `exp:<id>`, `exp:none` or `exp:?`. | No |

Exit codes for `check`: `0` clean, `1` enrolled, `2` error (e.g. jq missing), `3` inconclusive.

## Reading the verdict

- **ENROLLED (ID xxx via ENTRYPOINT)** — an assignment is cached for that model and launch path and is being sent.
- **CLEAN as of <time>** — no assignment at the last cache refresh. A new one can arrive at any later refresh, including mid-session.
- **INCONCLUSIVE** — no readable slot for that model. Says nothing either way.

The ID is the first three characters of an opaque token. IDs seen in the wild (Oct–Nov 2026): `dba`, `34e`, `763`, `eab`, `c0e`. Not every ID changes behaviour.

## Opting out — read before running

Quit every Claude Code session first (terminal and Desktop app); a running one can write the assignment back.

`optout` deletes only the `atis` and `experimentKey` fields from each slot. Every other setting is left alone. A timestamped backup goes to `~/.claude/am-i-nerfed/backups/` first; `restore` puts it back. **Backups are full copies of `~/.claude.json`, which holds your account details (email, account and organization IDs). Delete them when you no longer need them.**

Deleting the keys is not enough on its own — the next remote refresh re-enrolls you. Users report that this blocks it (not verified by this project):

```sh
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
```

Anthropic documents that variable as equivalent to disabling auto-updates, telemetry, error reporting and `/bug` together. Users report it also stops remote feature-flag updates; not verified by this project. You take on that trade-off.

Alternative, not shipped here: a local proxy that strips the `x-cc-atis` header, with `ANTHROPIC_BASE_URL` pointed at it and `_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL=1`. More robust, but that variable is internal and undocumented and can vanish in any release.

## What this cannot do

- Detect every experiment. CLEAN means no `x-cc-atis` assignment. `~/.claude.json` also holds ordinary named feature-flag experiments (`cachedExperimentData`), which this tool lists by count but does not read or interpret.
- Change anything assigned on Anthropic's servers by account rather than by header.
- Change client-side feature flags that the assignment selects (prompt variants, reminders).
- Tell you whether an experiment made your results better or worse.

## Privacy

Reads `~/.claude.json` (or `$CLAUDE_CONFIG_DIR`), `~/.claude/projects/`, `~/.claude/settings.json`, and its own backup folder. Touches your shell profile only with `--apply-env=profile`, and your Windows user environment variables only with `--apply-env=user`. Makes no network calls. Never prints your login token; whole experiment tokens appear only with `--full`.

## Compatibility

See `COMPAT.md` for the Claude Code versions this was verified against, the slot layout, and the transcript field (`atis-latch`). If a release removes the slots, `check` reports INCONCLUSIVE. If a release renames the assignment field, `check` could report CLEAN wrongly, because clean slots never contain the field — compare your Claude Code version with COMPAT.md.

## Sources

- anthropics/claude-code issues [#75607](https://github.com/anthropics/claude-code/issues/75607), [#88383](https://github.com/anthropics/claude-code/issues/88383)
- [phase3dev/claude-code-workarounds](https://github.com/phase3dev/claude-code-workarounds)
- r/ClaudeCode: [experiment IDs and behaviour measurements](https://www.reddit.com/r/ClaudeCode/comments/1xr66pd/)

## License

MIT
