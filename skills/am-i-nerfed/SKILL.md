---
name: am-i-nerfed
description: Checks whether this Claude Code account is enrolled in a server-side experiment (the x-cc-atis request header) by reading Claude Code's local flag cache, then explains the verdict in plain English. Use when the user asks "am I nerfed", whether they are in an experiment or A/B test, what x-cc-atis or an experiment ID means, or why Claude Code suddenly behaves differently.
---

# am-i-nerfed

Users invoke this skill with `/am-i-nerfed`, or with `/am-i-nerfed:am-i-nerfed`, the form
the command list shows. Both work (verified on Claude Code 2.1.319).

A thin wrapper. All the logic lives in `am-i-nerfed.sh` at the plugin root, two
directories above this skill's base directory: `<base directory>/../../am-i-nerfed.sh`.

## 1. Run the check

```bash
bash "<base directory>/../../am-i-nerfed.sh" check
```

It is read-only, local-only and fast. The exit status is the verdict, not a failure:
0 clean, 1 enrolled, 3 inconclusive, 2 error (if it says jq is missing, tell the user how
to install jq and stop). Never add `--full`: whole tokens may identify the account.

## 2. Explain the verdict

Go through the "Verdict per model" lines in plain English:

- **ENROLLED (ID xyz via ENTRYPOINT)**: the newest cached flag snapshot for that model,
  for that entrypoint (`cli` = terminal, `claude-desktop` = the Desktop app, `sdk-cli` =
  the SDK), carries experiment assignment `xyz`. Claude Code sends it with every request
  as the `x-cc-atis` header. Assignment is decided server-side for the whole account and
  can change at any refresh.
- **CLEAN as of TIME**: the newest snapshot for that model had no assignment at TIME.
  Nothing is known about later, so say "as of".
- **INCONCLUSIVE**: there is no readable snapshot for that model, so nothing can be said.
- A "superseded" note means an older, no-longer-current snapshot once carried an ID.
- A note that slots were written after the last optout means Claude Code is still
  fetching flags: either the opt-out variable is not set for every way the user launches
  Claude Code, or it does not block refreshes.

Stay neutral. Community reports for some IDs (dba, 34e, 763, eab, c0e; Oct–Nov 2026)
describe behaviour changes: two to three times more replies with several tool calls, Bash
commands two to three times longer, less narration, and possibly faster usage-meter burn,
with the same model string and token speed. That evidence shows behaviour changes, not
lower quality. Do not call the user "nerfed" or speculate beyond this.

If they ask about past sessions, run `bash "<base directory>/../../am-i-nerfed.sh" history`
and summarise the tally by date and ID.

## 3. If they want to opt out

Do not run `optout`, `restore` or `--apply-env` yourself unless the user explicitly asks
you to. Recommend instead that they quit every Claude Code session, this one and the
Desktop app included (a running session can write its cached assignment back), then run
`am-i-nerfed.sh optout` in an ordinary terminal and read the trade-offs it prints.
Anthropic documents `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` as equivalent to disabling
automatic updates, `/bug`, error reporting and telemetry together. Users report that it
also blocks re-enrollment and stops every other remote flag update; that is not verified
by this project, so say so. You may run `optout --dry-run` to show what would change.

Never print or repeat whole tokens, e-mail addresses, account or organization IDs.
