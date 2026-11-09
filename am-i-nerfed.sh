#!/usr/bin/env bash
# am-i-nerfed: detect, explain and opt out of Claude Code server-side
# experiment assignments (the x-cc-atis request header).
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
# Requires bash 3.2+ and jq 1.6+.                 SPDX-License-Identifier: MIT

# The jq programs are single-quoted on purpose: their $names are jq variables.
# shellcheck disable=SC2016

set -u
set -o pipefail
umask 077
export LC_ALL=C

AMN_VERSION=0.1.2
ENV_VAR=CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
PROG=${0##*/}

# ----------------------------------------------------------------- helpers --

say()  { printf '%s\n' "$*"; }
warn() { printf 'am-i-nerfed: %s\n' "$*" >&2; }
die()  { warn "$*"; exit 2; }
die_usage() { warn "$*"; printf 'Run "%s --help" for usage.\n' "$PROG" >&2; exit 2; }

# Show paths under $HOME as ~/... (display only).
tildify() {
  local h=${HOME:-} rest
  if [ -z "$h" ] || [ "$h" = / ]; then printf '%s' "$1"; return; fi
  case $1 in
    "$h") printf '%s' '~' ;;
    "$h"/*) rest=${1#"$h"/}; printf '%s/%s' '~' "$rest" ;;
    *) printf '%s' "$1" ;;
  esac
}

TMP_LIST=""
cleanup() {
  local IFS='
' f
  set -f
  for f in $TMP_LIST; do [ -n "$f" ] && rm -f "$f"; done
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# make_tmp DIR -> REPLY = new private temp file in DIR (same filesystem as the
# file it will replace, so the final mv is an atomic rename).
make_tmp() {
  REPLY=$(mktemp "$1/.am-i-nerfed.XXXXXX") || die "cannot create a temporary file in $(tildify "$1")"
  TMP_LIST="$TMP_LIST$REPLY
"
}

# unique_path DIR NAME SUFFIX -> REPLY = DIR/NAME.<UTC timestamp>[_NN]SUFFIX
# Names sort chronologically in the C locale.
unique_path() {
  local base p n=0
  base="$1/$2.$(date -u +%Y%m%dT%H%M%SZ)"
  p=$base$3
  while [ -e "$p" ]; do
    n=$((n + 1))
    p=$(printf '%s_%02d%s' "$base" "$n" "$3")
  done
  REPLY=$p
}

# Follow symlinks so atomic replacement writes the real file, not over the link.
resolve_link() {
  local p=$1 t n=0
  while [ -L "$p" ]; do
    n=$((n + 1))
    [ "$n" -le 40 ] || die "too many levels of symlinks: $(tildify "$1")"
    t=$(readlink "$p") || die "cannot resolve symlink: $(tildify "$p")"
    case $t in
      /*) p=$t ;;
      *) p=$(dirname "$p")/$t ;;
    esac
  done
  printf '%s' "$p"
}

need_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  warn "jq is required but was not found on PATH."
  printf '%s\n' \
    "  macOS:          brew install jq   (macOS 15 and later also ship /usr/bin/jq)" \
    "  Debian/Ubuntu:  sudo apt-get install jq" \
    "  Fedora:         sudo dnf install jq" \
    "  Arch:           sudo pacman -S jq" >&2
  exit 2
}

# jq 1.7+ keeps integer literals beyond 2^53 intact when it rewrites a file;
# older jq rounds them. Unknown version strings count as old.
jq_keeps_big_numbers() {
  local v
  v=$(jq --version 2>/dev/null) || return 1
  v=${v#jq-}
  case $v in
    1.[0-6] | 1.[0-6].* | 1.[0-6]-* | 0.*) return 1 ;;
    1.* | [2-9].*) return 0 ;;
    *) return 1 ;;
  esac
}

guard_big_numbers() {
  jq_keeps_big_numbers && return 0
  if ! jq -e '[.. | numbers | select(. > 9007199254740991 or . < -9007199254740991)] | length == 0' "$1" >/dev/null 2>&1; then
    die "$(tildify "$1") contains integers beyond 2^53 and this jq ($(jq --version 2>/dev/null)) would round them when rewriting the file. Install jq 1.7 or newer and re-run. Nothing was changed."
  fi
}

# Sets CFG_STATE to "missing" or "ok"; exits 2 if the file is unreadable or not JSON.
config_state() {
  if [ ! -e "$CONFIG_FILE" ]; then CFG_STATE=missing; return 0; fi
  [ -r "$CONFIG_FILE" ] || die "cannot read $(tildify "$CONFIG_FILE")"
  jq -e 'type == "object"' "$CONFIG_FILE" >/dev/null 2>&1 ||
    die "$(tildify "$CONFIG_FILE") is not a valid JSON object (Claude Code may be writing it right now; retry in a moment)."
  CFG_STATE=ok
}

confirm() {
  local ans
  [ "$ASSUME_YES" = 1 ] && return 0
  if [ -t 0 ]; then
    printf '%s [y/N] ' "$1"
    IFS= read -r ans || ans=
    case $ans in
      [yY] | [yY][eE][sS]) return 0 ;;
    esac
    say "Not applied."
    return 1
  fi
  say "Not applied: stdin is not a terminal. Re-run with --yes to apply it without a prompt."
  return 1
}

# newest_backup PREFIX -> REPLY = newest $BACKUP_DIR/PREFIX.*.bak, or empty.
newest_backup() {
  local f
  REPLY=""
  for f in "$BACKUP_DIR/$1".*.bak; do
    [ -f "$f" ] && REPLY=$f
  done
}

# Prints the UTC time of the newest optout as a JSON string, or null when there
# was none or a restore happened after it.
last_optout_json() {
  local o r ots rts
  newest_backup claude.json; o=$REPLY
  newest_backup pre-restore.claude.json; r=$REPLY
  if [ -z "$o" ]; then printf 'null'; return 0; fi
  ots=${o##*/claude.json.}; ots=${ots%.bak}; ots=${ots%%_*}
  if [ -n "$r" ]; then
    rts=${r##*/pre-restore.claude.json.}; rts=${rts%.bak}; rts=${rts%%_*}
    if [[ ! $rts < $ots ]]; then printf 'null'; return 0; fi
  fi
  case $ots in
    [0-9][0-9][0-9][0-9][0-1][0-9][0-3][0-9]T[0-2][0-9][0-5][0-9][0-6][0-9]Z)
      printf '"%s-%s-%sT%s:%s:%sZ"' "${ots:0:4}" "${ots:4:2}" "${ots:6:2}" "${ots:9:2}" "${ots:11:2}" "${ots:13:2}" ;;
    *) printf 'null' ;;
  esac
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

script_abs() {
  local p=$0 d
  case $p in
    */*) ;;
    *) p=$(command -v "$p" 2>/dev/null || printf '%s' "$p") ;;
  esac
  d=$(cd "$(dirname "$p")" 2>/dev/null && pwd -P) || d=$(dirname "$p")
  printf '%s/%s' "$d" "${p##*/}"
}

# ------------------------------------------------------------------- paths --
# Mirrors Claude Code: with CLAUDE_CONFIG_DIR set, everything lives inside it;
# otherwise the config file is ~/.claude.json and the rest is under ~/.claude.

if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  CONFIG_HOME=${CLAUDE_CONFIG_DIR%/}
  CONFIG_FILE=$CONFIG_HOME/.claude.json
else
  : "${HOME:?HOME is not set}"
  CONFIG_HOME=$HOME/.claude
  CONFIG_FILE=$HOME/.claude.json
fi
PROJECTS_DIR=$CONFIG_HOME/projects
SETTINGS_FILE=$CONFIG_HOME/settings.json
BACKUP_DIR=$CONFIG_HOME/am-i-nerfed/backups
ASSUME_YES=0

# ---------------------------------------------------------------- jq code --
# No single quotes allowed inside these programs.

JQ_LIB='
def as_list: if type == "object" then [.[]] elif type == "array" then . else [] end;
def nonempty_str: if type == "string" and length > 0 then . else null end;
def utc: if type == "number" and . >= 0 and . < 32503680000000
  then (. / 1000 | floor | todate | sub("T"; " ") | sub("Z$"; "")) else null end;
def norm_model: if type == "string"
  then (ascii_downcase | sub("\\[.*$"; "") | sub("^claude-"; "") | sub("-[0-9]{8}$"; "")) else "" end;
def cfg_org: (.oauthAccount? // null) | if type == "object" then (.organizationUuid | nonempty_str) else null end;

# One cache slot -> normalized record. Never carries the org value itself.
def slot_rec($org; $full):
  (if (.data | type) == "object" then .data else null end) as $d
  | (if $d == null then null else $d.atis end) as $a
  | (if $d == null then null else $d.experimentKey end) as $k
  | (if $d == null then "unknown"
     elif ($a | type) == "string" and ($a | length) > 0 then "assigned"
     elif $a != null and $a != "" then "unknown"
     elif $k != null then "unknown"
     else "unassigned" end) as $state
  | { model: (.model | nonempty_str),
      entrypoint: (.entrypoint | nonempty_str),
      at: (if (.at | type) == "number" then .at else null end),
      time: (.at | utc),
      state: $state,
      id: (if $state == "assigned" then $a[0:3] else null end),
      experimentKey: (if $k == null then null elif ($k | type) == "string" then $k else ($k | tojson) end),
      org: (if $org == null or (.org | type) != "string" then "unknown"
            elif .org == $org then "current" else "other" end) }
  + (if $full and $state == "assigned" then {atis: $a} else {} end);

# All slots; current = newest slot for its (model, entrypoint) among slots that
# are not from another organization.
def all_recs($full):
  (if type == "object" then . else {} end) as $cfg
  | ($cfg | cfg_org) as $org
  | ($cfg.clientDataCacheSlots | as_list | map(objects | slot_rec($org; $full))) as $r
  | ($r | map(select(.org != "other")) | group_by([.model, .entrypoint])
     | map({key: ([.[0].model, .[0].entrypoint] | tojson), value: (map(.at // -1) | max)})
     | from_entries) as $newest
  | $r | map(. + {current: (.org != "other" and ((.at // -1) == $newest[[.model, .entrypoint] | tojson]))});

def model_verdict:
  . as $rs
  | ($rs | map(select(.current))) as $cur
  | ($cur | map(select(.state == "assigned"))) as $asg
  | ($cur | map(select(.state == "unassigned"))) as $cln
  | ($cur | map(.at // empty) | max) as $asof
  | { model: $rs[0].model,
      verdict: (if ($asg | length) > 0 then "ENROLLED" elif ($cln | length) > 0 then "CLEAN" else "INCONCLUSIVE" end),
      ids: ($asg | map(.id) | unique),
      enrolled: ($asg | map({entrypoint, id, experimentKey, time})),
      as_of: $asof,
      as_of_time: ($asof | utc),
      entrypoints: ($cur | map(.entrypoint // "-") | unique),
      superseded_assignments: ($rs | map(select((.current | not) and .org != "other" and .state == "assigned") | {entrypoint, id, time})),
      reason: (if ($asg | length) > 0 or ($cln | length) > 0 then null
               elif ($rs | all(.org == "other")) then "only slots from a different organization"
               else "no slot with readable assignment data" end),
      slots: ($rs | length) };

def no_slot_model($m; $why):
  {model: $m, verdict: "INCONCLUSIVE", ids: [], enrolled: [], as_of: null, as_of_time: null,
   entrypoints: [], superseded_assignments: [], reason: $why, slots: 0};

# cachedExperimentData holds ordinary named feature-flag experiments, separate
# from the x-cc-atis assignment. Only its size is used; names and values never are.
def analyze($want; $full):
  ((.cachedExperimentData? // null) | if type == "object" or type == "array" then length else null end) as $ced
  | all_recs($full) as $recs
  | ($recs | group_by(.model) | map(model_verdict) | sort_by(-(.as_of // 0))) as $all
  | (if $want == "" then $all
     else ($all | map(select((.model | norm_model) == ($want | norm_model)))) as $m
       | if ($m | length) > 0 then $m else [no_slot_model($want; "no slot for this model")] end
     end) as $models
  | ($models | to_entries | map({key: (.value.model | tojson), value: .key}) | from_entries) as $rank
  | ($recs | map(select($want == "" or ((.model | norm_model) == ($want | norm_model))))
     | sort_by([($rank[.model | tojson] // 999), -(.at // 0)])) as $shown
  | (if ($models | any(.verdict == "ENROLLED")) then "enrolled"
     elif ($models | length) == 0 or ($models | any(.verdict == "INCONCLUSIVE")) then "inconclusive"
     else "clean" end) as $status
  | { status: $status,
      exit_code: (if $status == "clean" then 0 elif $status == "enrolled" then 1 else 3 end),
      slot_count: ($recs | length),
      cached_experiment_data_count: $ced,
      models: $models,
      slots: $shown };

def strip_slot:
  if type == "object" then (if (.data | type) == "object" then .data |= del(.atis, .experimentKey) else . end) else . end;
def strip_assignments:
  (.clientDataCacheSlots | type) as $t
  | if $t == "object" then .clientDataCacheSlots |= map_values(strip_slot)
    elif $t == "array" then .clientDataCacheSlots |= map(strip_slot)
    else . end;

def pad($n): tostring | . + ((" " * ($n - length)) // "");
def table($rows):
  if ($rows | length) == 0 then empty else
    ($rows | map(length) | max) as $nc
    | ([range(0; $nc)] | map(. as $i | $rows | map(.[$i] // "" | tostring | length) | max)) as $w
    | $rows[] | [range(0; $nc) as $i | (.[$i] // "" | pad($w[$i]))] | join("  ") | sub(" +$"; "")
  end;
'

JQ_CHECK_TEXT='
def note: (if .org == "other" then "other org, ignored" elif .current then "newest" else "superseded" end)
  + (if .state == "unknown" then ", unreadable" else "" end);
def verdict_text:
  if .verdict == "ENROLLED" then
    "ENROLLED (" + (.enrolled | map("ID " + .id + " via " + (.entrypoint // "unknown entrypoint")
      + (if .experimentKey != null then ", experimentKey " + .experimentKey else "" end)) | join("; ")) + ")"
  elif .verdict == "CLEAN" then
    "CLEAN as of " + (.as_of_time // "an unknown time") + " UTC (state after that time unknown)"
  else "INCONCLUSIVE (" + (.reason // "no slot") + ")" end;
(if $optout == null then null else ($optout | fromdateiso8601 * 1000) end) as $optout_ms
| . as $r
| "am-i-nerfed \($ver): \($cfg)",
  "",
  ( if $present != "1" then
      "No Claude Code config file here. Claude Code has not run with this config directory,",
      "or CLAUDE_CONFIG_DIR points somewhere else."
    elif $r.slot_count == 0 then
      "No experiment-cache slots (clientDataCacheSlots) in this file. Claude Code may not have",
      "fetched remote flags yet, or this version keeps them somewhere else (see COMPAT.md)."
    elif ($r.slots | length) == 0 then
      "\($r.slot_count) experiment-cache slot(s), none for this model."
    else
      "\($r.slot_count) experiment-cache slot(s)" + (if ($r.slots | length) < $r.slot_count then ", \($r.slots | length) shown" else "" end) + ":",
      "",
      table([["MODEL", "ENTRYPOINT", "SLOT TIME (UTC)", (if $full then "TOKEN" else "ID" end), "EXPERIMENT KEY", "NOTE"]]
        + ($r.slots | map([.model // "-", .entrypoint // "-", .time // "-",
             (if $full then (.atis // "-") else (.id // "-") end), .experimentKey // "-", note])))
    end ),
  "",
  "Verdict per model:",
  ( if ($r.models | length) == 0 then "  none (no slots to judge)"
    else table($r.models | map(["  " + (.model // "(no model name)"), verdict_text])) end ),
  ( $r.models[] | select((.superseded_assignments | length) > 0) | . as $m | .superseded_assignments[]
    | "  note: \($m.model // "?"): an older, superseded \(.entrypoint // "?") slot from \(.time // "?") UTC carried ID \(.id)." ),
  ( if $optout_ms != null and ($r.slots | any((.at // 0) > $optout_ms)) then
      "  note: slots were written after your last optout (\($optout | sub("T"; " ") | sub("Z$"; "")) UTC), so Claude Code",
      "        is still fetching remote flags: either \($envvar)=1 is not set for every launch,",
      "        or it does not block refreshes."
    else empty end ),
  "",
  "Overall: \($r.status | ascii_upcase) (exit \($r.exit_code))",
  ( if ($r.cached_experiment_data_count // 0) > 0 then
      "Not checked: \($r.cached_experiment_data_count) named feature-flag experiment(s) in cachedExperimentData (ordinary flags, not x-cc-atis)."
    else empty end ),
  ( if ($r.slots | any(.state == "assigned")) then
      "",
      "ID = first 3 characters of the slot assignment token (data.atis), which Claude Code sends as",
      "the x-cc-atis request header. "
        + (if $full then "Whole tokens are shown (--full): they may be tied to your account, so do not post them."
           else "Whole tokens are hidden; --full shows them." end)
    else empty end ),
  ( if $r.slot_count > 0 then
      "Verdicts describe what Claude Code last cached on this machine. The server can assign,",
      "change or end an experiment at any refresh, even mid-session."
    else empty end ),
  ( if $r.status == "enrolled" then
      "To opt out: quit every Claude Code session (CLI and Desktop), then run: \($self) optout"
    else empty end )
'

# Streams per-file raw lines (jq -R -n, many files) and emits one record per
# {"type":"atis-latch"} transcript entry. The entry has no timestamp of its own,
# so it is dated by the nearest earlier timestamped entry in the same file (or
# the first one, when it comes before any).
JQ_HIST_SCAN='
reduce (inputs | . as $raw | input_filename as $fn | ($raw | fromjson?) | objects | {fn: $fn, o: .}) as $x
  ({last: {}, first: {}, recs: []};
   ($x.o.timestamp | if type == "string" and length >= 10 then . else null end) as $t
   | (if $t != null then (.last[$x.fn] = $t | if .first[$x.fn] == null then .first[$x.fn] = $t else . end) else . end)
   | if $x.o.type == "atis-latch" then
       .recs += [{fn: $x.fn, ts: .last[$x.fn], session: ($x.o.sessionId | nonempty_str),
                  atis: ($x.o.atis | if type == "string" then . else "" end)}]
     else . end)
| . as $s
| $s.recs[]
| (.ts // $s.first[.fn]) as $ts
| {fn, date: (if $ts == null then "unknown" else $ts[0:10] end),
   session: (.session // (.fn | split("/") | last | sub("\\.jsonl$"; ""))),
   id: (if (.atis | length) > 0 then .atis[0:3] else null end)}
  + (if $full and (.atis | length) > 0 then {atis: .atis} else {} end)
'

JQ_HIST_SUMMARY='
def summary:
  . as $recs
  | { files_with_records: ($recs | map(.fn) | unique | length),
      sessions: ($recs | map(.session) | unique | length),
      sessions_with_id: ($recs | map(select(.id != null) | .session) | unique | length),
      by_date: ($recs | group_by([.date, (.id // "")])
        | map({date: .[0].date, id: (.[0].id // "none"), sessions: (map(.session) | unique | length), records: length})
        | sort_by(.date, .id)),
      ids: ($recs | map(select(.id != null)) | group_by(.id)
        | map({id: .[0].id, sessions: (map(.session) | unique | length),
               first_date: (map(.date) | min), last_date: (map(.date) | max)}
              + (if $full then {tokens: (map(.atis // empty) | unique)} else {} end))) };
'

JQ_HIST_TEXT='
summary as $s
| "am-i-nerfed \($ver): history from \($dir)",
  "",
  ( if ($s.files_with_records) == 0 then
      "No experiment identifiers found. None of the \($total) transcript file(s) contains an",
      "atis-latch entry, which is the only place Claude Code was seen recording the assignment in",
      "transcripts (Claude Code 2.1.291 to 2.1.319, see COMPAT.md). This Claude Code version may not",
      "record it, or these sessions predate the field. Nothing to tally."
    else
      "Scanned \($total) transcript file(s); \($s.files_with_records) contain atis-latch entries.",
      "",
      table([["DATE (UTC)", "ID", "SESSIONS", "ENTRIES"]] + ($s.by_date | map([.date, .id, .sessions, .records]))),
      "",
      "Sessions that recorded an experiment ID: \($s.sessions_with_id) of \($s.sessions).",
      ( if ($s.ids | length) > 0 then
          "IDs seen: " + ($s.ids | map("\(.id) (\(.sessions) session(s), \(.first_date) to \(.last_date))") | join("; ")),
          ( if $full then ($s.ids[] | "  \(.id): " + (.tokens | join(", "))) else empty end )
        else empty end ),
      "\"none\" = an atis-latch entry with an empty value: no assignment recorded at that point.",
      "Dates come from the nearest earlier timestamped entry in the same transcript."
    end )
'

STATUSLINE_JQ='(.model.id? // "" | ascii_downcase | sub("\\[.*$"; "")) as $m | [($c[0].clientDataCacheSlots? // {})[] | objects | select((.model? // "" | ascii_downcase) == $m)] as $s | ([$s[] | select(.entrypoint == ($ENV.CLAUDE_CODE_ENTRYPOINT // "cli"))] | if length > 0 then . else $s end | max_by(.at // 0)) as $n | if $n == null or ($n.data | type) != "object" then "exp:?" elif ($n.data.atis | type) == "string" and ($n.data.atis | length) > 0 then "exp:" + $n.data.atis[0:3] else "exp:none" end'

# ------------------------------------------------------------------- usage --

usage() {
  cat <<EOF
am-i-nerfed $AMN_VERSION: detect, explain and opt out of Claude Code experiment
assignments (the x-cc-atis request header). Unofficial.

Usage: $PROG [command] [options]

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
                 --apply-env=profile    ...or append an export line to your shell profile
                 --profile FILE         the shell profile to use with --apply-env=profile
                 --yes                  apply --apply-env edits without asking
  restore      put back the newest optout backup (the current file is saved first)
  statusline   print a ready-to-paste status line snippet (exp:<id>, exp:none, exp:?)
                 --render               the status line command itself (reads Claude Code JSON on stdin)

Files (CLAUDE_CONFIG_DIR is honored):
  config       $(tildify "$CONFIG_FILE")
  transcripts  $(tildify "$PROJECTS_DIR")
  backups      $(tildify "$BACKUP_DIR")

Reads undocumented Claude Code internals and may break on any release. Makes no
network calls. Never prints account or OAuth values.
EOF
}

# ------------------------------------------------------------------- check --

cmd_check() {
  local fmt=text full=false model="" present=1 analysis optout rc
  while [ $# -gt 0 ]; do
    case $1 in
      --json) fmt=json ;;
      --full) full=true ;;
      --model)
        [ $# -ge 2 ] || die_usage "check: --model needs a model ID"
        model=$2; shift ;;
      --model=*) model=${1#--model=} ;;
      -h | --help) usage; exit 0 ;;
      *) die_usage "check: unknown option: $1" ;;
    esac
    shift
  done
  need_jq
  config_state
  if [ "$CFG_STATE" = missing ]; then
    present=0
    analysis=$(jq -n -c --arg want "$model" --argjson full "$full" "$JQ_LIB"' null | analyze($want; $full)') ||
      die "internal error while analyzing"
  else
    analysis=$(jq -c --arg want "$model" --argjson full "$full" "$JQ_LIB"' analyze($want; $full)' "$CONFIG_FILE") ||
      die "could not analyze $(tildify "$CONFIG_FILE")"
  fi
  optout=$(last_optout_json)

  if [ "$fmt" = json ]; then
    printf '%s\n' "$analysis" | jq --arg ver "$AMN_VERSION" --arg cfg "$CONFIG_FILE" --arg present "$present" \
      --argjson optout "$optout" '
      (if $optout == null then null else ($optout | fromdateiso8601 * 1000) end) as $optout_ms
      | {tool: "am-i-nerfed", version: $ver, generated_at: (now | floor | todate),
         config_file: $cfg, config_present: ($present == "1")}
        + .
        + {last_optout: $optout,
           slots_written_after_last_optout: (if $optout_ms == null then null
             else [.slots[] | select((.at // 0) > $optout_ms)] | length end)}'
  else
    printf '%s\n' "$analysis" | jq -r --arg ver "$AMN_VERSION" --arg cfg "$(tildify "$CONFIG_FILE")" \
      --arg present "$present" --argjson full "$full" --arg self "$0" --arg envvar "$ENV_VAR" \
      --argjson optout "$optout" "$JQ_LIB$JQ_CHECK_TEXT"
  fi
  rc=$(printf '%s\n' "$analysis" | jq -r '.exit_code') || rc=2
  exit "$rc"
}

# ----------------------------------------------------------------- history --

cmd_history() {
  local fmt=text full=false total records
  while [ $# -gt 0 ]; do
    case $1 in
      --json) fmt=json ;;
      --full) full=true ;;
      -h | --help) usage; exit 0 ;;
      *) die_usage "history: unknown option: $1" ;;
    esac
    shift
  done
  need_jq
  if [ -d "$PROJECTS_DIR" ]; then
    total=$(find "$PROJECTS_DIR" -type f -name '*.jsonl' | wc -l | tr -d ' ')
  else
    total=0
  fi
  if [ "$total" = 0 ]; then
    if [ "$fmt" = json ]; then
      jq -n --arg ver "$AMN_VERSION" --arg dir "$PROJECTS_DIR" \
        '{tool: "am-i-nerfed", version: $ver, transcripts_dir: $dir, files_scanned: 0, files_with_records: 0,
          field: "atis-latch", sessions: 0, sessions_with_id: 0, by_date: [], ids: [],
          note: "no session transcripts found"}'
    else
      say "am-i-nerfed $AMN_VERSION: history from $(tildify "$PROJECTS_DIR")"
      say ""
      say "No session transcripts (*.jsonl) here. Nothing to tally."
    fi
    exit 0
  fi
  # Cheap pre-filter: only files that mention atis-latch at all get parsed.
  # The jq pass then counts structured entries only, never mentions in text.
  records=$(find "$PROJECTS_DIR" -type f -name '*.jsonl' -exec grep -lF 'atis-latch' {} + 2>/dev/null |
    tr '\n' '\0' | xargs -0 jq -R -n -c --argjson full "$full" "$JQ_LIB$JQ_HIST_SCAN")
  if [ "$fmt" = json ]; then
    printf '%s\n' "$records" | jq -s --arg ver "$AMN_VERSION" --arg dir "$PROJECTS_DIR" --argjson total "$total" \
      --argjson full "$full" "$JQ_HIST_SUMMARY"'
      summary as $s
      | {tool: "am-i-nerfed", version: $ver, transcripts_dir: $dir, files_scanned: $total, field: "atis-latch"}
        + $s
        + (if $s.files_with_records == 0 then {note: "no atis-latch entries found in any transcript"} else {} end)'
  else
    printf '%s\n' "$records" | jq -s -r --arg ver "$AMN_VERSION" --arg dir "$(tildify "$PROJECTS_DIR")" \
      --argjson total "$total" --argjson full "$full" "$JQ_LIB$JQ_HIST_SUMMARY$JQ_HIST_TEXT"
  fi
  exit 0
}

# ------------------------------------------------------------------ optout --

env_advice() {
  cat <<EOF

Blocking re-enrollment
  1. Quit every Claude Code session, CLI and Desktop. A session that is still running can
     write its cached assignment back.
  2. Users report that deleting the keys is not enough on its own, because the next remote
     refresh re-enrolls you, and that starting Claude Code with this variable set blocks
     that; not verified by this project:

       export $ENV_VAR=1

     Users also report that DISABLE_GROWTHBOOK=1 on its own no longer blocks it; not verified
     by this project. To set the variable for every launch, re-run with --apply-env (sets it
     in $(tildify "$SETTINGS_FILE") "env") or --apply-env=profile (appends the export line
     to your shell profile).
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
EOF
}

optout_config() {
  local dry=$1 target dir plan n before after backup tmp
  target=$(resolve_link "$CONFIG_FILE") || exit 2
  plan=$(jq -r "$JQ_LIB"'
    .clientDataCacheSlots | as_list | .[] | objects
    | select(.data | type == "object")
    | select(.data | has("atis") or has("experimentKey"))
    | "  - \(.model // "unknown model") via \(.entrypoint // "unknown entrypoint"), slot \(.at | utc // "of unknown time") UTC: ID \(.data.atis | if type == "string" and length > 0 then .[0:3] else "-" end), experimentKey \(.data.experimentKey // "-" | tostring)"' \
    "$target") || die "could not read slots from $(tildify "$target")"
  if [ -z "$plan" ]; then
    say "Already clean: no slot in $(tildify "$target") has data.atis or data.experimentKey."
    say "Nothing changed; no backup made."
    return 0
  fi
  n=$(printf '%s\n' "$plan" | grep -c .)
  if [ "$dry" = 1 ]; then
    say "Dry run. Would remove data.atis and data.experimentKey from $n slot(s) in $(tildify "$target"):"
  else
    say "Removing data.atis and data.experimentKey from $n slot(s) in $(tildify "$target"):"
  fi
  say "$plan"
  say "All other keys, including the other flags in those slots, stay as they are."
  say "Close every Claude Code session (CLI and Desktop) first: a running one can write the assignment back."
  if [ "$dry" = 1 ]; then
    say "Nothing changed."
    return 0
  fi

  guard_big_numbers "$target"
  before=$(cksum <"$target") || die "cannot read $(tildify "$target")"
  mkdir -p "$BACKUP_DIR" || die "cannot create $(tildify "$BACKUP_DIR")"
  unique_path "$BACKUP_DIR" claude.json .bak
  backup=$REPLY
  if ! { cp -p "$target" "$backup" && chmod 600 "$backup" && cmp -s "$target" "$backup"; }; then
    die "could not write a verified backup to $(tildify "$backup"). Nothing changed."
  fi

  dir=$(dirname "$target")
  make_tmp "$dir"
  tmp=$REPLY
  # cp -p first so the new file keeps the original's mode, owner and xattrs.
  if ! { cp -p "$target" "$tmp" && jq "$JQ_LIB"' strip_assignments' "$target" >"$tmp"; }; then
    die "rewriting failed. Nothing changed. Backup: $(tildify "$backup")"
  fi
  if ! jq -n -e --slurpfile a "$target" --slurpfile b "$tmp" "$JQ_LIB"'
      ($a[0] | strip_assignments) == $b[0]
      and ([$b[0].clientDataCacheSlots | as_list | .[] | objects | .data | objects
            | select(has("atis") or has("experimentKey"))] | length) == 0' >/dev/null 2>&1; then
    die "the rewritten file did not verify. Nothing changed. Backup: $(tildify "$backup")"
  fi
  after=$(cksum <"$target")
  if [ "$before" != "$after" ]; then
    die "$(tildify "$target") changed while am-i-nerfed was working (is Claude Code running?). Nothing changed; quit Claude Code and retry."
  fi
  mv -f "$tmp" "$target" || die "could not replace $(tildify "$target"); it is unchanged. Backup: $(tildify "$backup")"
  say "Done. Previous file backed up to $(tildify "$backup") (undo: $PROG restore)."
}

default_profile() {
  case ${SHELL##*/} in
    zsh) printf '%s/.zshrc' "${ZDOTDIR:-$HOME}" ;;
    bash)
      if [ "$(uname -s)" = Darwin ]; then printf '%s/.bash_profile' "$HOME"; else printf '%s/.bashrc' "$HOME"; fi ;;
    fish) printf '%s/.config/fish/config.fish' "$HOME" ;;
    *) printf '%s/.profile' "$HOME" ;;
  esac
}

# The only file outside the config directory this script ever reads or writes,
# and only when asked to with --apply-env=profile.
apply_env_profile() {
  local f=$1 line disp stamp
  [ -n "$f" ] || f=$(default_profile)
  case $f in
    *.fish) line="set -gx $ENV_VAR 1" ;;
    *) line="export $ENV_VAR=1" ;;
  esac
  disp=$(tildify "$f")
  if [ -f "$f" ] && grep -qxF "$line" "$f"; then
    say "Already in $disp: $line"
    return 0
  fi
  if [ -f "$f" ] && grep -qF "$ENV_VAR" "$f"; then
    say "Note: $disp already mentions $ENV_VAR; the line appended below comes last, so it wins."
  fi
  stamp=$(date -u +%Y-%m-%d)
  say ""
  say "Edit to $disp (append 2 lines):"
  say "  + # added by am-i-nerfed optout $stamp: blocks Claude Code experiment re-enrollment"
  say "  + $line"
  confirm "Apply this edit?" || return 0
  mkdir -p "$(dirname "$f")" || die "cannot create $(tildify "$(dirname "$f")")"
  printf '\n# added by am-i-nerfed optout %s: blocks Claude Code experiment re-enrollment\n%s\n' "$stamp" "$line" >>"$f" ||
    die "could not append to $disp"
  say "Done. Open a new terminal before starting Claude Code. The Claude Desktop app does not read"
  say "shell profiles; for it, use --apply-env=settings."
}

apply_env_settings() {
  local f=$SETTINGS_FILE target disp cur backup="" tmp
  disp=$(tildify "$f")
  target=$f
  if [ -e "$f" ]; then
    target=$(resolve_link "$f") || exit 2
    jq -e 'type == "object"' "$target" >/dev/null 2>&1 ||
      die "$disp is not a plain JSON object (comments or a syntax error?); not editing it. Add \"env\": {\"$ENV_VAR\": \"1\"} by hand."
    cur=$(jq -r --arg k "$ENV_VAR" '
      if .env == null then "<unset>"
      elif (.env | type) != "object" then "<not-an-object>"
      elif (.env | has($k)) then (.env[$k] | tostring)
      else "<unset>" end' "$target") || die "could not read $disp"
    case $cur in
      "<not-an-object>") die "\"env\" in $disp is not an object; not editing it." ;;
      1) say "Already set in $disp: \"env\": {\"$ENV_VAR\": \"1\"}"; return 0 ;;
    esac
  else
    cur="<unset>"
  fi
  say ""
  if [ -e "$f" ]; then
    say "Edit to $disp (other keys untouched; jq re-indents the file):"
  else
    say "New file $disp:"
  fi
  say '  "env": {'
  if [ "$cur" = "<unset>" ]; then
    say "  +  \"$ENV_VAR\": \"1\""
  else
    say "  -  \"$ENV_VAR\": $(jq -n --arg v "$cur" '$v')"
    say "  +  \"$ENV_VAR\": \"1\""
  fi
  say '  }'
  confirm "Apply this edit?" || return 0
  mkdir -p "$(dirname "$target")" || die "cannot create $(tildify "$(dirname "$target")")"
  make_tmp "$(dirname "$target")"
  tmp=$REPLY
  if [ -e "$target" ]; then
    mkdir -p "$BACKUP_DIR" || die "cannot create $(tildify "$BACKUP_DIR")"
    unique_path "$BACKUP_DIR" settings.json .bak
    backup=$REPLY
    if ! { cp -p "$target" "$backup" && cmp -s "$target" "$backup"; }; then
      die "could not back up $disp. Nothing changed."
    fi
    if ! { cp -p "$target" "$tmp" &&
      jq --arg k "$ENV_VAR" '.env = ((.env // {}) + {($k): "1"})' "$target" >"$tmp"; }; then
      die "could not write the new $disp. Nothing changed."
    fi
  else
    jq -n --arg k "$ENV_VAR" '{env: {($k): "1"}}' >"$tmp" || die "could not write $disp"
    chmod 644 "$tmp" 2>/dev/null
  fi
  mv -f "$tmp" "$target" || die "could not replace $disp; it is unchanged."
  say "Done.${backup:+ Previous file backed up to $(tildify "$backup").}"
  say "New Claude Code sessions get $ENV_VAR=1 from settings.json. Whether this applies early"
  say "enough to stop the very first flag fetch, and whether the Desktop app honors it, was not"
  say "verified; \"$PROG check\" will show it (see step 3 above)."
}

cmd_optout() {
  local dry=0 apply="" profile="" profile_set=0
  while [ $# -gt 0 ]; do
    case $1 in
      -n | --dry-run) dry=1 ;;
      --apply-env) apply=default ;;
      --apply-env=settings) apply=settings ;;
      --apply-env=profile) apply=profile ;;
      --apply-env=*) die_usage "optout: --apply-env takes 'settings' or 'profile'" ;;
      --profile)
        [ $# -ge 2 ] || die_usage "optout: --profile needs a file"
        profile=$2; profile_set=1; shift ;;
      --profile=*) profile=${1#--profile=}; profile_set=1 ;;
      -y | --yes) ASSUME_YES=1 ;;
      -h | --help) usage; exit 0 ;;
      *) die_usage "optout: unknown option: $1" ;;
    esac
    shift
  done
  if [ "$profile_set" = 1 ]; then
    case $apply in
      "") die_usage "optout: --profile only makes sense with --apply-env=profile" ;;
      settings) die_usage "optout: --profile cannot be combined with --apply-env=settings" ;;
      *) apply=profile ;;
    esac
  fi
  [ "$apply" = default ] && apply=settings
  need_jq
  config_state
  if [ "$CFG_STATE" = missing ]; then
    say "No Claude Code config file at $(tildify "$CONFIG_FILE"); nothing to remove."
  else
    optout_config "$dry"
  fi
  env_advice
  case $apply in
    "") ;;
    *)
      if [ "$dry" = 1 ]; then
        say ""
        say "Dry run: --apply-env was not applied."
      elif [ "$apply" = profile ]; then
        apply_env_profile "$profile"
      else
        apply_env_settings
      fi ;;
  esac
  exit 0
}

# ----------------------------------------------------------------- restore --

cmd_restore() {
  local b target disp tmp snap="" before after
  case ${1:-} in
    "") ;;
    -h | --help) usage; exit 0 ;;
    *) die_usage "restore: unknown option: $1" ;;
  esac
  need_jq
  newest_backup claude.json
  b=$REPLY
  [ -n "$b" ] || die "no backups in $(tildify "$BACKUP_DIR"), so there is nothing to restore (optout makes one whenever it changes the file)."
  jq -e 'type == "object"' "$b" >/dev/null 2>&1 || die "the newest backup, $(tildify "$b"), is not valid JSON; not restoring it."
  target=$(resolve_link "$CONFIG_FILE") || exit 2
  disp=$(tildify "$target")
  if [ -f "$target" ] && cmp -s "$b" "$target"; then
    say "$disp already matches the newest backup ($(tildify "$b")). Nothing to do."
    exit 0
  fi
  make_tmp "$(dirname "$target")"
  tmp=$REPLY
  if [ -f "$target" ]; then
    before=$(cksum <"$target") || die "cannot read $disp"
    unique_path "$BACKUP_DIR" pre-restore.claude.json .bak
    snap=$REPLY
    if ! { cp -p "$target" "$snap" && chmod 600 "$snap" && cmp -s "$target" "$snap"; }; then
      die "could not save the current $disp before restoring. Nothing changed."
    fi
    # Keep the current file's mode and owner; take the content from the backup.
    if ! { cp -p "$target" "$tmp" && cat "$b" >"$tmp"; }; then
      die "could not prepare the restored file. Nothing changed."
    fi
    after=$(cksum <"$target")
    [ "$before" = "$after" ] || die "$disp changed while am-i-nerfed was working (is Claude Code running?). Nothing changed."
  else
    cp -p "$b" "$tmp" || die "could not prepare the restored file. Nothing changed."
  fi
  mv -f "$tmp" "$target" || die "could not replace $disp; it is unchanged."
  say "Restored $disp from $(tildify "$b")."
  [ -n "$snap" ] && say "The file it replaced is saved as $(tildify "$snap")."
  say "This rolls the whole file back to that backup, not only the assignment: anything Claude Code"
  say "changed in it since then (settings, project list, newer slots) is undone too."
  say "If you set $ENV_VAR=1 (by hand or with optout --apply-env), remove it from"
  say "$(tildify "$SETTINGS_FILE") \"env\" or your shell profile to let Claude Code refresh flags again."
  exit 0
}

# -------------------------------------------------------------- statusline --

statusline_render() {
  local input out
  command -v jq >/dev/null 2>&1 || { say "exp:?"; exit 0; }
  input=$(cat 2>/dev/null) || input=""
  if [ ! -f "$CONFIG_FILE" ]; then say "exp:?"; exit 0; fi
  out=$(jq -r --arg input "$input" --arg ep "${CLAUDE_CODE_ENTRYPOINT:-}" "$JQ_LIB"'
    (($input | fromjson?) // {}) as $in
    | ($in | if type == "object" then (.model | if type == "object" then (.id // "" | tostring)
                                                elif type == "string" then . else "" end)
             else "" end) as $m
    | all_recs(false) as $recs
    | [$recs[] | select(.current and $m != "" and ((.model | norm_model) == ($m | norm_model)))] as $cur
    | ([$cur[] | select(.entrypoint == $ep)] | if length > 0 then . else $cur end) as $pick
    | if ($pick | length) == 0 then "exp:?"
      elif ($pick | any(.state == "assigned")) then "exp:" + ([$pick[] | select(.state == "assigned") | .id] | unique | join(","))
      elif ($pick | any(.state == "unassigned")) then "exp:none"
      else "exp:?" end' "$CONFIG_FILE" 2>/dev/null) || out=""
  say "${out:-exp:?}"
  exit 0
}

cmd_statusline() {
  local self cmd_a cmd_b
  case ${1:-} in
    --render) statusline_render ;;
    -h | --help) usage; exit 0 ;;
    "") ;;
    *) die_usage "statusline: unknown option: $1" ;;
  esac
  need_jq
  self=$(script_abs)
  cmd_a="$(shell_quote "$self") statusline --render"
  cmd_b="jq -r --slurpfile c \"\${CLAUDE_CONFIG_DIR:-\$HOME}/.claude.json\" '$STATUSLINE_JQ' 2>/dev/null || echo 'exp:?'"
  say "Status line: shows exp:<id>, exp:none or exp:? for the model in use."
  say ""
  say "Option A, uses this script. Paste into $(tildify "$SETTINGS_FILE"):"
  jq -n --arg c "$cmd_a" '{statusLine: {type: "command", command: $c}}'
  say ""
  say "Option B, standalone (needs only jq; skips the other-organization check):"
  jq -n --arg c "$cmd_b" '{statusLine: {type: "command", command: $c}}'
  say ""
  say "Already have a status line? Run /statusline in Claude Code and ask it to append the output of:"
  say "  $cmd_a"
  say ""
  say "exp:<id>  the newest slot for this model carries an assignment (first 3 characters)"
  say "exp:none  the newest slot for this model carries none"
  say "exp:?     no slot for this model, or it could not be read"
  exit 0
}

# -------------------------------------------------------------------- main --

main() {
  local cmd=check
  if [ $# -gt 0 ]; then
    case $1 in
      check | history | optout | restore | statusline) cmd=$1; shift ;;
      help | -h | --help) usage; exit 0 ;;
      version | --version) say "am-i-nerfed $AMN_VERSION"; exit 0 ;;
      -*) ;;
      *) die_usage "unknown command: $1" ;;
    esac
  fi
  case $cmd in
    check) cmd_check "$@" ;;
    history) cmd_history "$@" ;;
    optout) cmd_optout "$@" ;;
    restore) cmd_restore "$@" ;;
    statusline) cmd_statusline "$@" ;;
  esac
}

main "$@"
