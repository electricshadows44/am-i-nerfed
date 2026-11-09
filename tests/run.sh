#!/usr/bin/env bash
# Test runner for am-i-nerfed.
#
# Uses only the synthetic fixtures in tests/fixtures. Every run gets its own
# temporary HOME and CLAUDE_CONFIG_DIR, so the real ~/.claude.json and
# ~/.claude are never read or written.
#
#   tests/run.sh                       run everything with /bin/bash
#   BASH_UNDER_TEST=/path/bash tests/run.sh
#   VERBOSE=1 tests/run.sh             also list passing checks
#
# Exit status: 0 all passed, 1 failures.

# jq and sh -c programs are single-quoted on purpose.
# shellcheck disable=SC2016

set -u
LC_ALL=C
export LC_ALL

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
SCRIPT=$ROOT/am-i-nerfed.sh
FIX=$ROOT/tests/fixtures
BASH_BIN=${BASH_UNDER_TEST:-/bin/bash}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/amn-tests.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT

unset CLAUDE_CONFIG_DIR CLAUDE_CODE_ENTRYPOINT ZDOTDIR
export SHELL=/bin/zsh
export HOME=$WORK/home-unused
mkdir -p "$HOME"

PASS=0
FAIL=0
GROUP=""
LOG=$WORK/all-output.log      # every output except --full runs
FULL_LOG=$WORK/full-output.log
: >"$LOG"
: >"$FULL_LOG"

TOK_DBA=dba7c1f0e2d94b3a8c6e5f4d3c2b1a09-tokentail-01

# ------------------------------------------------------------------ helpers --

group() { GROUP=$1; [ -n "${VERBOSE:-}" ] && printf '\n## %s\n' "$1"; return 0; }
pass() { PASS=$((PASS + 1)); [ -n "${VERBOSE:-}" ] && printf 'ok    %s\n' "$1"; return 0; }
fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL  [%s] %s\n' "$GROUP" "$1"
  [ $# -gt 1 ] && printf '      %s\n' "$2"
  return 0
}

# setup FIXTURE: fresh temp config dir (copy of the fixture) and temp HOME.
setup() {
  CASE=$(mktemp -d "$WORK/case.XXXXXX")
  CFG=$CASE/config
  mkdir -p "$CFG" "$CASE/home"
  [ -n "${1:-}" ] && cp -R "$FIX/$1/." "$CFG/"
  rm -f "$CFG/.gitkeep"
  [ -f "$CFG/.claude.json" ] && chmod 600 "$CFG/.claude.json"
  export HOME=$CASE/home
  export CLAUDE_CONFIG_DIR=$CFG
  unset CLAUDE_CODE_ENTRYPOINT
  STDIN=/dev/null
}

# amn ARGS...: run the script; sets RC, leaves stdout/stderr in $WORK/out, $WORK/err.
amn() {
  "$BASH_BIN" "$SCRIPT" "$@" >"$WORK/out" 2>"$WORK/err" <"$STDIN"
  RC=$?
  local log=$LOG
  case " $* " in *" --full "*) log=$FULL_LOG ;; esac
  { printf '\n$ am-i-nerfed %s  [%s]\n' "$*" "$GROUP"; cat "$WORK/out" "$WORK/err"; } >>"$log"
}

t_rc() {
  if [ "$RC" = "$1" ]; then pass "$2"; else fail "$2" "expected exit $1, got $RC; stderr: $(head -c 300 "$WORK/err")"; fi
}
t_has() {
  if grep -qF -- "$1" "$WORK/out"; then pass "$2"; else fail "$2" "stdout lacks: $1"; fi
}
t_err() {
  if grep -qF -- "$1" "$WORK/err"; then pass "$2"; else fail "$2" "stderr lacks: $1"; fi
}
t_lacks() {
  if grep -qF -- "$1" "$WORK/out" "$WORK/err"; then fail "$2" "output contains: $1"; else pass "$2"; fi
}
t_line() { # exact line match, ignoring trailing spaces
  if sed 's/ *$//' "$WORK/out" | grep -qxF -- "$1"; then pass "$2"; else fail "$2" "no line: $1"; fi
}
t_json() { # jq expression must be true on stdout
  if jq -e "$1" "$WORK/out" >/dev/null 2>&1; then pass "$2"; else fail "$2" "jq false: $1"; fi
}
t_ok() { # description, then a command that must succeed
  local d=$1
  shift
  if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi
}
same_file() { cmp -s "$1" "$2"; }
backups() { find "$CFG/am-i-nerfed/backups" -type f -name "$1" 2>/dev/null | wc -l | tr -d ' '; }
is_private() { [ -n "$(find "$1" -prune -perm 0600 2>/dev/null)" ]; }

# The expected optout result, computed independently of the script.
strip_expected() {
  jq -S '.clientDataCacheSlots |= map_values(if (.data | type) == "object" then .data |= del(.atis, .experimentKey) else . end)' "$1"
}

# --------------------------------------------------------------- check: CLI --

group "check clean"
setup clean
amn check
t_rc 0 "clean exits 0"
t_line "Overall: CLEAN (exit 0)" "overall verdict line"
t_has "claude-opus-5-5   CLEAN as of 2026-10-30 10:00:00 UTC (state after that time unknown)" "opus-5-5 clean as of its newest slot"
t_has "claude-fable-5-1  CLEAN as of 2026-10-25 09:30:00 UTC" "fable-5-1 clean"
t_has "claude-opus-4-8   CLEAN as of 2026-09-15 07:45:00 UTC" "opus-4-8 clean"
t_has "superseded" "older slot marked superseded"
t_lacks "ENROLLED" "no ENROLLED anywhere"
amn
t_rc 0 "check is the default command"
amn --json
t_rc 0 "--json alone runs check"
t_json '.status == "clean" and .exit_code == 0 and (.models | length) == 3' "json status clean"
t_json '[.slots[] | select(.state != "unassigned")] | length == 0' "json: every slot unassigned"
t_json '[.slots[] | has("atis")] | any | not' "json: no atis field without --full"

group "check enrolled"
setup enrolled
amn check
t_rc 1 "enrolled exits 1"
t_has "claude-opus-5-5   ENROLLED (ID dba via cli, experimentKey exp_fixture_dba)" "opus-5-5 enrolled dba"
t_has "claude-fable-5-1  ENROLLED (ID 34e via claude-desktop, experimentKey exp_fixture_34e)" "fable enrolled 34e"
t_has "claude-opus-4-8   CLEAN as of 2026-09-15 07:45:00 UTC" "opus-4-8 still clean"
t_line "Overall: ENROLLED (exit 1)" "overall enrolled"
t_lacks "tokentail" "whole token hidden by default"
amn check --json
t_rc 1 "json exit 1"
t_json '.status == "enrolled" and ([.models[] | select(.verdict == "ENROLLED") | .ids[]] | sort) == ["34e", "dba"]' "json ids"
t_lacks "tokentail" "json hides whole token"
amn check --full
t_rc 1 "--full exit 1"
t_has "$TOK_DBA" "--full shows the whole token"
t_has "TOKEN" "--full header"
amn check --json --full
t_json '.status == "enrolled"' "json --full parses"
t_json '[.slots[] | .atis // empty] | length == 2' "json --full carries 2 tokens"

group "check mixed entrypoints"
setup mixed
amn check
t_rc 1 "mixed exits 1"
t_has "claude-opus-5-5   ENROLLED (ID 763 via cli, experimentKey exp_fixture_763)" "cli slot enrolled, desktop clean -> enrolled via cli only"
t_lacks "via claude-desktop, experimentKey exp_fixture_763" "desktop not reported enrolled"
t_has "claude-fable-5-1  CLEAN as of 2026-10-30 10:00:00 UTC" "superseded assignment does not count"
t_has "an older, superseded claude-desktop slot from 2026-10-20 08:00:00 UTC carried ID eab" "superseded assignment noted"
t_has "claude-opus-4-8   CLEAN as of 2026-10-25 09:30:00 UTC" "other-org assignment ignored"
t_has "other org, ignored" "other-org slot labeled"
t_has "claude-haiku-5-5  INCONCLUSIVE (no slot with readable assignment data)" "unreadable slot -> inconclusive"
amn check --model claude-fable-5-1
t_rc 0 "--model clean model exits 0"
t_lacks "claude-opus-5-5" "--model filters the table"
amn check --model opus-5-5
t_rc 1 "--model accepts a name without claude- prefix"
amn check --model 'claude-opus-5-5[1m]'
t_rc 1 "--model ignores a [1m] suffix"
amn check --model claude-haiku-5-5
t_rc 3 "--model unreadable exits 3"
amn check --model claude-nonexistent-9
t_rc 3 "--model without slot exits 3"
t_has "claude-nonexistent-9  INCONCLUSIVE (no slot for this model)" "no slot -> INCONCLUSIVE (no slot)"
amn check --json --model claude-nonexistent-9
t_json '.status == "inconclusive" and .models[0].reason == "no slot for this model"' "json no-slot reason"

group "check cachedExperimentData"
setup experiments
amn check
t_rc 0 "named experiments do not change the verdict"
t_line "Not checked: 3 named feature-flag experiment(s) in cachedExperimentData (ordinary flags, not x-cc-atis)." "count line printed"
t_ok "count line comes right after the Overall line" sh -c 'grep -A1 "^Overall: CLEAN (exit 0)$" "$1" | tail -1 | grep -q "^Not checked: 3 "' _ "$WORK/out"
t_lacks "fixture_named_exp" "no experiment name printed"
t_lacks "fixture-exp-id" "no experiment ID printed"
t_lacks "fixture-exp-value-marker" "no experiment value printed"
amn check --json
t_json '.cached_experiment_data_count == 3 and .status == "clean"' "json count"
t_lacks "fixture_named_exp" "json: no experiment name"
t_lacks "fixture-exp-value-marker" "json: no experiment value"
jq '.cachedExperimentData = {}' "$FIX/experiments/.claude.json" >"$CFG/.claude.json"
amn check
t_lacks "Not checked:" "empty cachedExperimentData: no count line"
amn check --json
t_json '.cached_experiment_data_count == 0' "empty cachedExperimentData: json count 0"
setup clean
amn check
t_lacks "Not checked:" "absent cachedExperimentData: no count line"
amn check --json
t_json '.cached_experiment_data_count == null' "absent cachedExperimentData: json null"

group "check missing / no slots / bad input"
setup missing
amn check
t_rc 3 "missing config exits 3"
t_has "No Claude Code config file here" "missing explained"
t_line "Overall: INCONCLUSIVE (exit 3)" "overall inconclusive"
amn check --json
t_rc 3 "missing json exits 3"
t_json '.config_present == false and .status == "inconclusive" and .slot_count == 0' "missing json"
setup noslots
amn check
t_rc 3 "no slots exits 3"
t_has "No experiment-cache slots" "no slots explained"
amn check --json
t_json '.config_present == true and .status == "inconclusive"' "no slots json"
setup clean
printf '{"clientDataCacheSlots": {' >"$CFG/.claude.json"
amn check
t_rc 2 "invalid JSON exits 2"
t_err "not a valid JSON object" "invalid JSON explained"
amn check --bogus
t_rc 2 "unknown option exits 2"
amn frobnicate
t_rc 2 "unknown command exits 2"
amn --help
t_rc 0 "--help exits 0"
t_has "statusline" "--help lists commands"

group "jq missing"
setup clean
mkdir -p "$CASE/emptybin"
PATH=$CASE/emptybin "$BASH_BIN" "$SCRIPT" check >"$WORK/out" 2>"$WORK/err" </dev/null
RC=$?
t_rc 2 "check without jq exits 2"
t_err "jq is required" "clear jq message"
PATH=$CASE/emptybin "$BASH_BIN" "$SCRIPT" history >"$WORK/out" 2>"$WORK/err" </dev/null
RC=$?
t_rc 2 "history without jq exits 2"
printf '{"model":{"id":"claude-opus-5-5"}}' >"$CASE/in.json"
PATH=$CASE/emptybin "$BASH_BIN" "$SCRIPT" statusline --render >"$WORK/out" 2>"$WORK/err" <"$CASE/in.json"
RC=$?
t_rc 0 "statusline --render without jq still exits 0"
t_line "exp:?" "statusline --render without jq prints exp:?"

group "config location"
setup enrolled
# Decoys in HOME must be ignored while CLAUDE_CONFIG_DIR is set.
mkdir -p "$HOME/.claude/projects/-decoy"
sed 's/dba7c1f0/9de7c1f0/' "$FIX/enrolled/.claude.json" >"$HOME/.claude.json"
printf '{"type":"atis-latch","atis":"9dedecoy","sessionId":"decoy"}\n' >"$HOME/.claude/projects/-decoy/decoy.jsonl"
amn check
t_has "ID dba" "reads CLAUDE_CONFIG_DIR/.claude.json"
t_lacks "9de" "ignores ~/.claude.json when CLAUDE_CONFIG_DIR is set"
amn history
t_lacks "9de" "ignores ~/.claude/projects when CLAUDE_CONFIG_DIR is set"
unset CLAUDE_CONFIG_DIR
cp "$FIX/enrolled/.claude.json" "$HOME/.claude.json"
amn check
t_rc 1 "without CLAUDE_CONFIG_DIR reads ~/.claude.json"
t_has "ID dba" "default location finds the assignment"
amn history
t_has "9de" "without CLAUDE_CONFIG_DIR reads ~/.claude/projects"

# ----------------------------------------------------------------- history --

group "history"
setup history
amn history
t_rc 0 "history exits 0"
t_has "Scanned 4 transcript file(s); 3 contain atis-latch entries." "file counts (subagent file has none)"
t_line "2026-10-20  none  1         2" "empty atis tallied as none"
t_line "2026-10-21  dba   1         1" "entry before midnight dated by preceding timestamp"
t_line "2026-10-22  dba   1         1" "entry after midnight dated to next day"
t_line "2026-10-23  34e   1         2" "entry before any timestamp uses the first timestamp"
t_has "Sessions that recorded an experiment ID: 2 of 3." "session summary"
t_has "IDs seen: 34e (1 session(s), 2026-10-23 to 2026-10-23); dba (1 session(s), 2026-10-21 to 2026-10-22)" "IDs summary"
t_lacks "eab" "text mentions of atis-latch are not counted"
t_lacks "tokentail" "whole tokens hidden"
amn history --json
t_rc 0 "history json exits 0"
t_json '.files_scanned == 4 and .files_with_records == 3 and .sessions == 3 and .sessions_with_id == 2' "history json counts"
t_json '(.by_date | map("\(.date)/\(.id)/\(.sessions)/\(.records)")) == ["2026-10-20/none/1/2","2026-10-21/dba/1/1","2026-10-22/dba/1/1","2026-10-23/34e/1/2"]' "history json rows"
t_lacks "tokentail" "history json hides tokens"
amn history --full
t_has "$TOK_DBA" "history --full shows whole tokens"

group "history without the field"
setup nofield
amn history
t_rc 0 "no field exits 0"
t_has "No experiment identifiers found. None of the 1 transcript file(s) contains an" "says so plainly"
t_lacks "763" "text mentions of atis are not counted"
amn history --json
t_json '.files_with_records == 0 and .by_date == [] and (.note | type) == "string"' "no-field json"
setup clean
amn history
t_rc 0 "no transcripts dir exits 0"
t_has "No session transcripts" "no transcripts explained"
amn history --json
t_json '.files_scanned == 0' "no transcripts json"

# ------------------------------------------------------------------ optout --

group "optout"
setup enrolled
orig=$CASE/original.json
cp -p "$CFG/.claude.json" "$orig"
amn optout --dry-run
t_rc 0 "dry run exits 0"
t_has "Dry run. Would remove" "dry run says so"
t_ok "dry run leaves the file alone" same_file "$orig" "$CFG/.claude.json"
t_ok "dry run makes no backup" test "$(backups 'claude.json.*.bak')" = 0
amn optout
t_rc 0 "optout exits 0"
t_has "Removing data.atis and data.experimentKey from 2 slot(s)" "optout lists what it removes"
t_has "export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1" "prints the env var line"
t_has "DISABLE_AUTOUPDATER, DISABLE_BUG_COMMAND," "states Anthropic's documented equivalence"
t_has "Automatic updates" "warns about auto-updates"
t_has "Users report that it also stops every remote feature-flag update" "flag freeze worded as a user report"
t_has "re-enrolls you, and that starting Claude Code with this variable set blocks" "re-enrollment block worded as a user report"
t_has "not verified by this project" "hedge present"
t_ok "exactly one backup" test "$(backups 'claude.json.*.bak')" = 1
bk=$(find "$CFG/am-i-nerfed/backups" -name 'claude.json.*.bak' | head -1)
t_ok "backup equals the original byte for byte" same_file "$orig" "$bk"
t_ok "backup is private (0600)" is_private "$bk"
t_ok "config mode preserved (0600)" is_private "$CFG/.claude.json"
strip_expected "$orig" >"$CASE/expected.json"
jq -S . "$CFG/.claude.json" >"$CASE/actual.json"
t_ok "only atis/experimentKey removed; everything else identical" same_file "$CASE/expected.json" "$CASE/actual.json"
t_ok "no atis or experimentKey left" jq -e '[.clientDataCacheSlots[] | .data | objects | select(has("atis") or has("experimentKey"))] | length == 0' "$CFG/.claude.json"
t_ok "other flags in the same slot kept" jq -e '.clientDataCacheSlots["k2b-000000000000e001"].data.fixture_date_flag == "2026-10-01"' "$CFG/.claude.json"
t_ok "oauthAccount untouched" jq -e --slurpfile o "$orig" '.oauthAccount == $o[0].oauthAccount' "$CFG/.claude.json"
amn check
t_rc 0 "check after optout is clean"
cp -p "$CFG/.claude.json" "$CASE/after-first.json"
amn optout
t_rc 0 "second optout exits 0"
t_has "Already clean" "second optout is a no-op"
t_ok "second optout makes no new backup" test "$(backups 'claude.json.*.bak')" = 1
t_ok "second optout leaves the file alone" same_file "$CASE/after-first.json" "$CFG/.claude.json"
t_ok "no temp files left behind" test "$(find "$CFG" -name '.am-i-nerfed.*' | wc -l | tr -d ' ')" = 0

group "optout mixed + symlink"
setup mixed
mv "$CFG/.claude.json" "$CASE/real-claude.json"
ln -s "$CASE/real-claude.json" "$CFG/.claude.json"
cp -p "$CASE/real-claude.json" "$CASE/original.json"
amn optout
t_rc 0 "optout through a symlink exits 0"
t_has "from 3 slot(s)" "removes from every slot, other org included"
t_ok "symlink kept" test -L "$CFG/.claude.json"
strip_expected "$CASE/original.json" >"$CASE/expected.json"
jq -S . "$CASE/real-claude.json" >"$CASE/actual.json"
t_ok "symlink target rewritten correctly" same_file "$CASE/expected.json" "$CASE/actual.json"
t_ok "data:null slot untouched" jq -e '.clientDataCacheSlots["k3c-000000000000m007"].data == null' "$CASE/real-claude.json"
amn check
t_rc 3 "after optout: clean except the unreadable slot (exit 3)"

group "optout missing / noslots"
setup missing
amn optout
t_rc 0 "optout with no config exits 0"
t_has "nothing to remove" "explains"
t_ok "creates no config file" test ! -e "$CFG/.claude.json"
setup noslots
cp -p "$CFG/.claude.json" "$CASE/original.json"
amn optout
t_rc 0 "optout with no slots exits 0"
t_has "Already clean" "no slots: already clean"
t_ok "no slots: unchanged" same_file "$CASE/original.json" "$CFG/.claude.json"

group "optout big integers"
setup enrolled
sed 's/"bigNumberProbe": 1234567/"bigNumberProbe": 12345678901234567890123/' "$FIX/enrolled/.claude.json" >"$CFG/.claude.json"
amn optout
v=$(jq --version 2>/dev/null)
case ${v#jq-} in
  1.[0-6] | 1.[0-6].* | 1.[0-6]-*)
    t_rc 2 "old jq refuses to round big integers"
    t_err "beyond 2^53" "explains the refusal" ;;
  *)
    t_rc 0 "jq 1.7+ optout with a big integer"
    t_ok "big integer literal preserved" grep -qF '12345678901234567890123' "$CFG/.claude.json" ;;
esac

group "optout --apply-env"
setup enrolled
amn optout --apply-env
t_rc 0 "apply-env without --yes on a non-tty exits 0"
t_has "Not applied" "refuses to edit without --yes when not interactive"
t_ok "settings.json not created" test ! -e "$CFG/settings.json"
amn optout --apply-env --yes
t_has '+  "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"' "shows the exact edit"
t_ok "settings.json created with the env var" jq -e '.env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC == "1"' "$CFG/settings.json"
amn optout --apply-env --yes
t_has "Already set" "settings edit is idempotent"
setup clean
printf '{\n  "model": "opus",\n  "env": {"OTHER_VAR": "keep-me", "%s": "0"},\n  "permissions": {"allow": ["Bash(ls:*)"]}\n}\n' CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC >"$CFG/settings.json"
cp -p "$CFG/settings.json" "$CASE/settings.orig"
amn optout --apply-env=settings --yes
t_rc 0 "apply-env=settings exits 0"
t_has '-  "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "0"' "shows the old value being replaced"
t_ok "env var now 1" jq -e '.env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC == "1"' "$CFG/settings.json"
t_ok "other settings kept" jq -e '.env.OTHER_VAR == "keep-me" and .model == "opus" and .permissions.allow == ["Bash(ls:*)"]' "$CFG/settings.json"
t_ok "settings backup made" test "$(backups 'settings.json.*.bak')" = 1
t_lacks "keep-me" "other env values are never printed"
setup clean
amn optout --apply-env=profile --profile "$HOME/.zshrc" --yes
t_rc 0 "apply-env=profile exits 0"
t_has "+ export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1" "shows the profile edit"
t_ok "profile line appended once" test "$(grep -cxF 'export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1' "$HOME/.zshrc")" = 1
amn optout --apply-env=profile --profile "$HOME/.zshrc" --yes
t_has "Already in" "profile edit is idempotent"
t_ok "still exactly one line" test "$(grep -cxF 'export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1' "$HOME/.zshrc")" = 1
amn optout --apply-env=profile --yes
t_ok "default profile for zsh is ~/.zshrc" test "$(grep -cxF 'export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1' "$HOME/.zshrc")" = 1
amn optout --apply-env=profile --profile "$HOME/.config/fish/config.fish" --yes
t_ok "fish profile gets fish syntax" grep -qxF 'set -gx CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC 1' "$HOME/.config/fish/config.fish"
amn optout --profile "$HOME/.zshrc"
t_rc 2 "--profile without --apply-env is rejected"
amn optout --dry-run --apply-env --yes
t_has "Dry run: --apply-env was not applied." "dry run does not apply env"
t_ok "dry run: no settings.json" test ! -e "$CFG/settings.json"
setup clean
printf '{ // comment\n "env": {} }\n' >"$CFG/settings.json"
amn optout --apply-env --yes
t_rc 2 "refuses to edit a settings.json it cannot parse"

# ----------------------------------------------------------------- restore --

group "restore"
setup clean
amn restore
t_rc 2 "restore without backups exits 2"
t_err "nothing to restore" "explains"
setup enrolled
cp -p "$CFG/.claude.json" "$CASE/original.json"
amn optout
amn check
t_rc 0 "clean after optout"
amn restore
t_rc 0 "restore exits 0"
t_ok "restore brings back the original bytes" same_file "$CASE/original.json" "$CFG/.claude.json"
t_ok "pre-restore snapshot saved" test "$(backups 'pre-restore.claude.json.*.bak')" = 1
t_has "rolls the whole file back" "warns that the whole file is rolled back"
amn check
t_rc 1 "enrolled again after restore"
amn restore
t_has "already matches the newest backup" "second restore is a no-op"
t_ok "no second snapshot" test "$(backups 'pre-restore.claude.json.*.bak')" = 1
# A refresh written after an optout is flagged by check.
setup enrolled
amn optout
jq '.clientDataCacheSlots["k9z-00000000000new01"] = {model: "claude-opus-5-5", entrypoint: "cli", at: 4102444800000, data: {}}' \
  "$CFG/.claude.json" >"$CASE/next.json" && cat "$CASE/next.json" >"$CFG/.claude.json"
amn check
t_has "slots were written after your last optout" "check flags flag refreshes after optout"
amn check --json
t_json '.slots_written_after_last_optout == 1 and (.last_optout | type) == "string"' "json flags refresh after optout"
amn restore
amn check
t_lacks "slots were written after your last optout" "no refresh warning after a restore"

# -------------------------------------------------------------- statusline --

group "statusline"
setup enrolled
printf '{"model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"}}' >"$CASE/in.json"
STDIN=$CASE/in.json
amn statusline --render
t_line "exp:dba" "enrolled model renders exp:dba"
printf '{"model":{"id":"claude-opus-5-5[1m]"}}' >"$CASE/in.json"
amn statusline --render
t_line "exp:dba" "[1m] suffix ignored"
printf '{"model":{"id":"claude-opus-4-8"}}' >"$CASE/in.json"
amn statusline --render
t_line "exp:none" "clean model renders exp:none"
printf '{"model":{"id":"claude-unknown-1"}}' >"$CASE/in.json"
amn statusline --render
t_line "exp:?" "model without slot renders exp:?"
printf 'not json' >"$CASE/in.json"
amn statusline --render
t_rc 0 "garbage stdin exits 0"
t_line "exp:?" "garbage stdin renders exp:?"
setup mixed
printf '{"model":{"id":"claude-opus-5-5"}}' >"$CASE/in.json"
STDIN=$CASE/in.json
export CLAUDE_CODE_ENTRYPOINT=cli
amn statusline --render
t_line "exp:763" "entrypoint cli picks the cli slot"
export CLAUDE_CODE_ENTRYPOINT=claude-desktop
amn statusline --render
t_line "exp:none" "entrypoint claude-desktop picks the desktop slot"
unset CLAUDE_CODE_ENTRYPOINT
setup missing
printf '{"model":{"id":"claude-opus-5-5"}}' >"$CASE/in.json"
STDIN=$CASE/in.json
amn statusline --render
t_line "exp:?" "missing config renders exp:?"

group "statusline snippet"
setup enrolled
amn statusline
t_rc 0 "snippet exits 0"
t_has '"statusLine"' "snippet has a statusLine block"
t_has "statusline --render" "option A calls the script"
awk '/^Option A/{f=1;next} f&&/^$/{exit} f' "$WORK/out" >"$CASE/a.json"
awk '/^Option B/{f=1;next} f&&/^$/{exit} f' "$WORK/out" >"$CASE/b.json"
t_ok "option A is valid JSON" jq -e '.statusLine.type == "command"' "$CASE/a.json"
t_ok "option B is valid JSON" jq -e '.statusLine.type == "command"' "$CASE/b.json"
printf '{"model":{"id":"claude-opus-5-5"}}' >"$CASE/in.json"
for opt in a b; do
  cmd=$(jq -r '.statusLine.command' "$CASE/$opt.json")
  out=$(/bin/sh -c "$cmd" <"$CASE/in.json" 2>/dev/null)
  t_ok "option $opt command renders exp:dba (got: $out)" test "$out" = "exp:dba"
done
printf '{"model":{"id":"claude-opus-4-8"}}' >"$CASE/in.json"
cmd=$(jq -r '.statusLine.command' "$CASE/b.json")
out=$(/bin/sh -c "$cmd" <"$CASE/in.json" 2>/dev/null)
t_ok "option B renders exp:none for a clean model (got: $out)" test "$out" = "exp:none"

group "README one-liner"
setup enrolled
cp "$CFG/.claude.json" "$HOME/.claude.json"   # the one-liner reads ~/.claude.json
line=$(grep -m1 "^jq -r '(.clientDataCacheSlots" "$ROOT/README.md")
if [ -z "$line" ]; then
  fail "README one-liner found"
else
  out=$(/bin/sh -c "$line" 2>&1)
  t_ok "one-liner lists the dba slot" sh -c 'printf "%s\n" "$1" | grep -qxF "$2"' _ "$out" \
    'claude-opus-5-5 | cli | 2026-11-01T12:00:00Z | dba | exp_fixture_dba'
  t_ok "one-liner shows none for a clean slot" sh -c 'printf "%s\n" "$1" | grep -qxF "$2"' _ "$out" \
    'claude-opus-4-8 | cli | 2026-09-15T07:45:00Z | none | -'
  cp "$FIX/noslots/.claude.json" "$HOME/.claude.json"
  out_empty=$(/bin/sh -c "$line" 2>&1)
  t_ok "one-liner prints nothing when there are no slots" test -z "$out_empty"
  case $out in *tokentail* | *sentinel*) fail "one-liner leaks token or account values" ;; *) pass "one-liner prints no token or account values" ;; esac
fi

# ------------------------------------------------------------- static/global --

group "static checks"
t_ok "script has no network tools" sh -c '! grep -v "^[[:space:]]*#" "$1" | grep -Eq "curl|wget|/dev/tcp|/dev/udp|[^a-z]nc [-a-z]|telnet|s_client"' _ "$SCRIPT"
t_ok "script parses under $BASH_BIN" "$BASH_BIN" -n "$SCRIPT"
if command -v shellcheck >/dev/null 2>&1; then
  t_ok "shellcheck am-i-nerfed.sh" shellcheck -s bash "$SCRIPT"
  t_ok "shellcheck tests/run.sh" shellcheck -s bash "$ROOT/tests/run.sh"
else
  printf 'skip  shellcheck not installed\n'
fi

group "no secrets in output"
if grep -qi 'sentinel' "$LOG" "$FULL_LOG"; then
  fail "no oauthAccount / userID / API key value ever printed" "$(grep -i -m3 'sentinel' "$LOG" "$FULL_LOG")"
else
  pass "no oauthAccount / userID / API key value ever printed"
fi
if grep -q 'tokentail' "$LOG"; then
  fail "whole tokens appear only in --full runs" "$(grep -m3 'tokentail' "$LOG")"
else
  pass "whole tokens appear only in --full runs"
fi

printf '\n%d passed, %d failed  (%s, %s)\n' "$PASS" "$FAIL" "$("$BASH_BIN" -c 'echo "bash $BASH_VERSION"')" "$(jq --version)"
[ "$FAIL" = 0 ]
