# Compatibility notes

What am-i-nerfed 0.1.2 was verified against, what was observed, and what was not
verified. All observations come from one machine and were made by reading files only:
no network inspection, and no token, account value or transcript text recorded.

## Verified environment

| | |
|---|---|
| Date | 2026-11-09 (UTC) |
| Claude Code | `claude --version` → `2.1.319 (Claude Code)` |
| Transcripts written by | Claude Code 2.1.291, 2.1.295, 2.1.296, 2.1.299, 2.1.300, 2.1.301, 2.1.302, 2.1.316, 2.1.318, 2.1.319 |
| OS | macOS |
| Shell | `/bin/bash` 3.2.57 (the macOS system bash) |
| jq | `jq-1.7.1-apple` (`/usr/bin/jq`) |
| shellcheck | 0.11.0 |
| `CLAUDE_CONFIG_DIR` | unset; the `CLAUDE_CONFIG_DIR` paths are exercised only by the test suite |

The test suite (`tests/run.sh`) passes under that bash and jq. It also passes on Linux, in
an `ubuntu:24.04` container with GNU bash 5.2.21, jq 1.7 and GNU coreutils, findutils and
grep; shellcheck was skipped there. The script sticks to POSIX tools plus jq and avoids
GNU-only and BSD-only flags.

## Config file: `~/.claude.json` → `clientDataCacheSlots`

Observed on the verification machine:

- `clientDataCacheSlots` is a top-level **JSON object** with 9 entries. Its keys are opaque
  20-character strings that do not contain the organization ID.
- Each entry has exactly five fields:

  | field | type | observed |
  |---|---|---|
  | `model` | string | `claude-opus-5-5`, `claude-fable-5-1`, `claude-opus-4-8` |
  | `entrypoint` | string | `claude-desktop` (8 slots), `cli` (1 slot) |
  | `org` | string (36-character UUID) | equal to `oauthAccount.organizationUuid` in every slot |
  | `at` | number, ms since epoch | 2026-09-13 to 2026-10-31 |
  | `data` | object | the remote flags (below) |

- **Several slots per (model, entrypoint)**: five for `claude-opus-5-5` / `claude-desktop`,
  two for `claude-fable-5-1` / `claude-desktop`, one for `claude-opus-4-8` / `cli`, each
  under a different key with a different `at`. am-i-nerfed reads the newest one per
  (model, entrypoint) as current and the others as superseded snapshots. That is an
  interpretation; Claude Code's selection logic was not inspected.
- `data` held 2–3 flags with obfuscated two-word names: an object of per-model booleans,
  a date string, and, in the two newest slots of one model only, a three-letter
  alphabetic string. That last value is not hex and is none of the reported IDs, so it
  is not treated as an assignment, and nothing suggests it is one. Flag names and values
  are deliberately not reproduced here, since the tool does not need them.
- **No slot contained `data.atis` or `data.experimentKey`.** This machine was clean, so
  the enrolled layout (`data.atis` = opaque token whose first 3 hex characters are the
  public ID, plus `data.experimentKey`) comes from the community reports listed in the
  README. It is exercised only through synthetic fixtures.
- The CLI session that built this tool ran `claude-opus-5-5` via `cli`, yet no `cli`
  slot for that model existed. The newest `cli` slot, for another model, dated from
  2026-09-13. Current CLI builds may write slots rarely or not at all, so for the CLI
  the slots can be stale and `history` is the more current signal.
- The file had mode 0600. `optout` and `restore` preserve the mode.

The script reads `slot.org` only to compare it with `oauthAccount.organizationUuid`, and
it outputs just `current`, `other` or `unknown`.

The file held no credential: no token, API-key or secret fields, only account details
(e-mail, name, account and organization IDs). On macOS, Claude Code keeps the login
token in the Keychain.

## Other experiment caches in `~/.claude.json` (counted, not read)

The same file holds a separate, ordinary feature-flag experiment cache. It is unrelated
to the `x-cc-atis` assignment. Observed on the verification machine:

- `cachedExperimentData`: an object with 11 entries keyed by feature-flag name. A re-read
  about 30 minutes later found 10: the cache changes as flags refresh. Each entry is
  `{experimentId, variationId, value}`:
  - `experimentId` is a readable lowercase slug (16–32 characters), equal to its key in
    3 of the 11 entries;
  - `variationId` is a number;
  - `value` is the flag value.

  No `experimentId` starts with a reported `x-cc-atis` ID.
- `cachedExperimentFeatures`: an array of 11 strings next to it.
- `cachedGrowthBookFeatures`: an object of 1,159 feature-flag values.

These look like conventional named A/B experiments: feature, experiment and variation.
`check` counts the entries of `cachedExperimentData` and prints
`Not checked: N named feature-flag experiment(s) in cachedExperimentData (ordinary flags,
not x-cc-atis).` after the Overall line. The `--json` output has the same count as
`cached_experiment_data_count`. Names and values are never read into output, and the
verdict ignores them. `optout` does not touch any of these caches. A CLEAN verdict means
"no `x-cc-atis` assignment", not "no experiments".

## Blind spot: a renamed assignment field

`check` calls a slot clean when its `data` object has no `atis`. Clean slots never contain
that field, so there is nothing to tell "no assignment" apart from "the assignment is now
stored under another name". If a release renamed or moved `data.atis`, `check` would
report CLEAN wrongly. Removing the slots altogether is detected: `check` reports
INCONCLUSIVE. Mitigations:

- Compare your Claude Code version with the one listed above.
- Run `history`. It reads a separate record, the `atis-latch` transcript entry, so a
  non-empty ID there while `check` says CLEAN points to this blind spot. If that entry is
  renamed too, `history` reports that it found none, which you can see.

## Plugin skill invocation

Verified on 2.1.319 with headless runs (`claude --plugin-dir <repo> -p …`), from the repo
and from an unrelated directory. The session's command list shows only
`am-i-nerfed:am-i-nerfed`. Both `/am-i-nerfed` and `/am-i-nerfed:am-i-nerfed` loaded the
skill and ran its `check` command. An unregistered command, run as a control, was
reported as "no such command". The bare form would presumably need the namespace if
another plugin defined a skill with the same name; that case was not tested.

## Transcripts: where the assignment is recorded

**Question:** do session transcripts (`~/.claude/projects/**/*.jsonl`) record the
experiment assignment, and under which field?

**Method** (values were never printed):

1. Enumerated every key path of every JSON line in every transcript and filtered the key
   names for `atis|experiment|growthbook|flag|feature|variant|assign|gate|cohort|bucket|treatment|statsig|ab_|x-cc`.
2. For each hit, recorded the entry type, key order, value types and lengths, and the
   neighbouring entries.
3. Cross-checked a plain `grep` count against a structural `jq` count.
4. Searched for structured `experimentKey` or `x-cc-atis` keys at any depth.
5. Planned to cross-reference the slots' token values against transcripts. That step was
   moot here, because no slot held a token.

**Finding:** the field exists. Claude Code writes standalone top-level JSONL entries of
exactly this shape, keys in this order:

```json
{"type":"atis-latch","atis":"","sessionId":"<session uuid>"}
```

- `atis` is a string: the assignment token, or `""` when there is none. On this machine
  it was `""` in all 381 entries found.
- `sessionId` always equalled the transcript's file name (`<sessionId>.jsonl`).
- The entry has **no** `timestamp`, `uuid` or `parentUuid`. am-i-nerfed dates each entry
  by the nearest earlier timestamped entry in the same file, or the file's first
  timestamp when it comes first. All Claude Code timestamps seen were UTC (`…Z`).
- It is written repeatedly, 5 to 58 times per session, roughly every 10–20 lines, next to
  other per-turn metadata entries such as `permission-mode`.
- It was present in **every top-level session transcript** (versions 2.1.291 to 2.1.319,
  2026-10-09 to 2026-11-09). It was **absent from every subagent transcript**
  (`<project>/<session>/subagents/agent-*.jsonl`).
- No transcript has a structured `experimentKey` or `x-cc-atis` key. Both strings
  occurred only as conversation text, in the build session itself. The one other
  filter hit, `params.safeguards[].classifier_context.rule_roots.flagSettings`, appears
  to name a settings source for permission rules, not an experiment.
- All 25 transcripts present had `entrypoint: cli`. No Desktop sessions were stored
  under `projects/`, so `history` cannot see Desktop sessions on a machine like this one.

Not verified:

- That a non-empty `atis` here equals the slot's `data.atis`. There was no enrolled data
  to compare. `history` uses the same first-3-characters rule as `check`.
- What "latch" means. The name suggests the value is fixed for the session or turn, which
  would make this the value actually sent, but Claude Code's code was not inspected.

**Retention:** Claude Code deletes transcripts older than `cleanupPeriodDays` (default 30).
During the build, its periodic cleanup removed the two transcripts last modified on
2026-10-09, taking the count from 25 to 23 files. `history` can only cover what is left.

## Paths

- Config file: `$CLAUDE_CONFIG_DIR/.claude.json` when `CLAUDE_CONFIG_DIR` is set,
  otherwise `~/.claude.json`.
- Transcripts: `$CLAUDE_CONFIG_DIR/projects` or `~/.claude/projects`.
- Settings for `--apply-env`: `$CLAUDE_CONFIG_DIR/settings.json` or `~/.claude/settings.json`.
- Backups: `<config dir>/am-i-nerfed/backups/`.

## Not verified

- That `data.atis` is what Claude Code sends as `x-cc-atis`. There was no traffic
  inspection; this comes from the community reports.
- That `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` blocks re-enrollment in 2.1.319, and
  what else it disables beyond Anthropic's documented equivalents.
- Whether `settings.json` `"env"` takes effect before the first flag fetch, and whether the
  Desktop app honors it. `check` reports slots written after the last optout, which shows
  whether it worked.
- Real Linux installs of Claude Code (only the test suite ran on Linux, in a container),
  and jq 1.6. The jq 1.6 path, including a guard that refuses to rewrite integers beyond
  2^53 with jq older than 1.7, is written but did not run.
- The proxy alternative in the README. It is documented only.

## Windows port (`am-i-nerfed.ps1`)

Verified on 2026-11-09 by reading files only, on one machine:

| | |
|---|---|
| OS | Windows 11 Pro 10.0.26300 |
| PowerShell | 7.6.9 (`pwsh`); Windows PowerShell 5.1 present, and refused as intended |
| Claude Code | `claude --version` → `2.1.319 (Claude Code)`, native Windows install |

- The config file is `%USERPROFILE%\.claude.json`; transcripts are under
  `%USERPROFILE%\.claude\projects`. The slot layout matches the macOS notes above;
  entrypoints seen were `cli` and `sdk-cli`.
- The project list in `.claude.json` held keys that differ only in case (the same path
  with an upper- and a lower-case drive letter). `ConvertFrom-Json` refuses such a file
  unless given `-AsHashtable`, which is why the README one-liner uses it and the script
  parses with System.Text.Json, which is case-sensitive.
- `optout` on a copy of the real config with a synthetic assignment injected: the result
  was byte-identical to the original file. The serializer reproduces Claude Code's
  formatting (2-space indent, LF, no final newline).
- `history` found `atis-latch` entries in 790 of about 8,500 transcripts (28 GB in all),
  some with a non-empty value, so the field is written on Windows too. A full scan took
  about 100 s on that corpus; the bash script scans the same files.
- `tests/run.ps1` passes under PowerShell 7.6.9. The symlink case needs Developer Mode or
  an elevated shell, and is skipped otherwise.

Not verified: PowerShell 7.2 to 7.5 (the script uses only .NET 6 APIs), the
`--apply-env=user` write itself (the test machine already had the variable set, and the
suite never writes the real user environment), and Claude Desktop on Windows reading
the user variable.

## If a Claude Code release breaks this

Signs: `check` reports "No experiment-cache slots", `history` reports no `atis-latch`
entries while you are still using Claude Code, or slots lose their `model` / `entrypoint`
/ `at` fields. Rerun the transcript method above, which prints no values, update this
file, and adjust the jq in `am-i-nerfed.sh`.
