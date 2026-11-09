# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [0.1.2] - 2026-11-08

### Added

- `check` prints `Not checked: N named feature-flag experiment(s) in cachedExperimentData
  (ordinary flags, not x-cc-atis).` after the Overall line when that cache has entries.
  It counts entries only and never prints names or values. `--json` carries
  `cached_experiment_data_count`: null when the key is absent, otherwise the entry count.
- Test fixture `experiments` with synthetic `cachedExperimentData`.

### Changed

- README:
  - the backup warning names what the file actually holds (account details, no token);
  - the flag-freeze claim is hedged;
  - Compatibility states the renamed-field blind spot;
  - "What this cannot do" now opens with "Detect every experiment";
  - Install gives the verified slash forms.
- SKILL.md gives the slash forms.
- COMPAT.md documents `cachedExperimentData` and the other caches, the renamed-field
  blind spot, and how the slash forms were verified.
- Version 0.1.2 in the script and both plugin manifests.

## [0.1.1] - 2026-11-08

### Changed

- README rewritten: shorter and neutral, with a commands table, a 60-second jq one-liner
  and an opt-out section to read before running.
- Env-var wording hedged in `optout` output, the `check` refresh-after-optout note, the
  usage text and the skill. Only Anthropic's documented equivalence (DISABLE_AUTOUPDATER,
  DISABLE_BUG_COMMAND, DISABLE_ERROR_REPORTING, DISABLE_TELEMETRY) is stated as fact. That
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` blocks re-enrollment and freezes cached
  flags is now worded as a user report, not verified by this project.
- Version 0.1.1 in the script and both plugin manifests. The README one-liner test follows
  the new one-liner.

## [0.1.0] - 2026-11-08

First release. Verified against Claude Code 2.1.319; see COMPAT.md.

### Added

- `am-i-nerfed.sh`, a single bash script for macOS and Linux whose only dependency is jq.
  It honors `CLAUDE_CONFIG_DIR` and makes no network calls.
  - `check` (default): table of every `clientDataCacheSlots` slot and a verdict per model
    (ENROLLED / CLEAN as of / INCONCLUSIVE). Supports `--json`, `--full` and `--model`.
    Exit codes: 0 clean, 1 enrolled, 3 inconclusive, 2 error. It flags slots written
    after the last optout.
  - `history`: tallies `{"type":"atis-latch"}` transcript entries by UTC date and ID,
    with `--json` and `--full`.
  - `optout`: timestamped 0600 backup, removes only `data.atis` and
    `data.experimentKey` from every slot, verifies the result and replaces the file
    atomically, then explains `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` and its side
    effects. `--apply-env[=settings|profile]` edits settings or the shell profile only
    after showing the edit. Also `--dry-run`. Idempotent.
  - `restore`: reverts the newest optout backup after saving the current file.
  - `statusline`: ready-to-paste `statusLine` snippets that render `exp:<id>`,
    `exp:none` or `exp:?`.
- Claude Code plugin (`.claude-plugin/`) with an `am-i-nerfed` skill that runs `check`
  and explains the verdict.
- Test suite (`tests/run.sh`) on synthetic fixtures; shellcheck clean.
- README, COMPAT, LICENSE (MIT).
