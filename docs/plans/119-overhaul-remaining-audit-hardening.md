---
id: 119
title: Overhaul O5-O12 - envelope, timestamps and env overrides, pane targeting, approvals check, ring cap, names, remote hosts
status: blocked
blocked-by: []
priority: 14
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-11-11
approval: "mdec-1111-fable-findings-plans: PLAN ONLY. Waits for Matthew's prioritisation from plan 115. Every install needs its own yes; O7 also changes skills text."
approved-by: pending (Matthew, via plan 115)
reviews: []
related: 115, 116, 118, 120, 121, 024, 028, 029, 034, 039, 040, 041, 096, 110, 111
---

The audit items that neither Fable's plans (a)-(e) nor the option 3/4 drafts sized.
Umbrella: plan 115.

| Audit finding | Phase |
|---|---|
| M3 envelope forgery | O5 |
| M4 sender-set timestamp | O5 |
| M5 env-steered attest walk (part) | O5 |
| M1 split-window mis-paste | O6a |
| M2 check-then-paste race | O6b |
| M8 approvals recipe | O7 (option 7) |
| M6 ring cap burnable | O12 |
| M7 name is identity (short-term) | O12 |
| M11 remote host values | O12 |
| L4 small quoting items | O12 |

All sizes here are **this plan's estimates** (marked P in plan 115); the reviewer did not
size these. Baseline is `main` at `8c249fc`.

## O5. Envelope hardening and test-mode-only overrides (step 5)

- **Scope.**
  - **M3: subjects.**
    - `--subject` rejects C0/C1 control characters and newlines, with exit 64 and a clear
      message.
    - A legacy stored subject is sanitised on display.
  - **M3: inline envelope.**
    - The inline envelope and human `recv`/`show` wrap the body in a per-message random
      fence:
      - `---- begin body <16hex> ----`;
      - `---- end body <16hex> ----`.
    - The fence value is generated at render time, so a body cannot predict it.
    - The header line `[cctrl peer message] from: … · verified` is emitted only outside the
      fence.
  - **M3: display.**
    - Human output strips C0 characters except LF and TAB, and shows CR and ESC as visible
      escapes.
    - `--json` output is unchanged (it is already escaped).
  - **M4.** `_peer_now_utc` honours `CCTRL_NOW_UTC` only in test mode.
  - **M5 and SH-S6.** One test-mode gate, `_cctrl_test_mode`, true only when the harness sets
    a marker that agents cannot reach by env alone. The gate is:
    - `CCTRL_TEST_MODE=1`, **and**
    - `CCTRL_DATA_DIR` under a directory holding the harness's `.cctrl-test-sandbox` file,
      which the harness creates in its own `mktemp -d`.

    Outside test mode, the attest path ignores `CCTRL_NOW_UTC`, the fault-injection variables
    (plan 116), plan 120's B4 tool-path override and the login-root override (plan 118), and
    records `env_override` when `CCTRL_SESSION_METADATA_DIR`, `TMUX_TMPDIR` or
    `CCTRL_TMUX_EXTRA_SERVERS` differ from the resolver defaults. The class cap itself is in
    plan 118.
  - **The paste sanitising cctrl relies on.** `peer doctor` gains a row with each running tmux
    server's version, and warns below 3.8, where `paste-buffer` may not rewrite ESC (audit
    handoff, item 2).
- **Closes.** M3, M4, M5 (the env half; plan 118 does the tool-path half), SH-S6 (the gate
  that B4 reuses).
- **Size.** 8 h (P).
- **Risk.** Low. The human output format changes; scripts use `--json`.
- **Tests.**
  - Hostile subjects are refused: LF, CR, ESC, NUL, a forged header.
  - A body containing a fake `[cctrl peer message] from: fleet-claude · verified` line and a
    fake fence renders inside the real fence.
  - Display stripping on the human paths.
  - `CCTRL_NOW_UTC` is ignored outside test mode, and the name-recycle guard holds.
  - The test-mode gate needs both parts.
  - Plan 121's E4 expected failures for M3 and M4 flip to passing.
- **Rollback.** The previous release. Stored messages are unchanged.
- **Depends on.** Plan 116's A0 (the sandbox marker path). Plan 121's E4 should land first.
- **Needs Matthew's yes:** the install on each Mac.

## O6a. Pane-id targeting (step 5)

- **Scope.**
  - Resolve the agent pane once (`list-panes -F '#{pane_id} #{pane_current_command}…'`,
    choosing the pane whose process tree holds the agent, not `head -1`).
  - Use that `%id` for the readiness check, the capture, the `paste-buffer -t` and the Enter,
    in `session say`, peer delivery and the nudge.
  - If the agent pane cannot be identified uniquely, refuse with exit 75 and say why. Never
    fall back to the active pane.
  - This is the targeting half of plan 039. Plan 039's remaining items are reviewed and
    either closed or carried into O6b.
- **Closes.** M1.
- **Size.** 6 h (P).
- **Risk.** Medium. It is the delivery path, but a small change: one resolution feeds the
  existing calls.
- **Tests.**
  - On a private socket: claude-stub in pane 0 and a zsh split active. The paste lands in
    pane 0, and zsh receives nothing.
  - Two agent panes, which is refused.
  - A pane that dies between the check and the paste, which fails cleanly.
  - All existing delivery tests unchanged.
- **Rollback.** The previous release.
- **Depends on.** O3.1 (so say is logged when the targeting changes). Independent of plan
  120.
- **Needs Matthew's yes:** the install on each Mac.

## O6b. Post-paste verification and modal detection (step 8, on plan 120's B6)

- **Scope.**
  - Built in Python, after B6 has moved delivery into `cctrl/tmux/pane.py`, so it is not
    written twice.
  - Plan 040: unique paste buffers, and a capture after paste that confirms the body's
    marker reached the prompt before the Enter.
  - Plan 041: invert modal detection to "known-ready prompt shapes", rather than "known
    modal shapes". Add Claude's "Do you want to proceed?" dialog.
  - A recheck right before the Enter; a timed-out tmux client is recorded as `unknown`, not
    `failed`, so senders do not resend blindly.
  - Plan 049 items 3-4 (lock-hold vs timeout, nudge dedupe) land here if still open.
- **Closes.** M2; plans 040 and 041.
- **Size.** 12 h (P).
- **Risk.** High. Keystroke delivery into live agents. It is behind B6's `peer_impl` toggle
  (a config key, SH-S5) for one release.
- **Tests.**
  - E10's fake agent TUI raises a modal between the check and the Enter, and the Enter is
    withheld.
  - Paste verification with a truncated paste.
  - The `unknown` state.
  - Pane fixtures replayed through both detectors.
  - A differential test against the sh path for the non-modal cases.
- **Rollback.** `peer_impl: sh` in `config.local.json`, or the previous release.
- **Depends on.** Plan 120's B6, plan 121's E10, and O6a.
- **Needs Matthew's yes:** the install on each Mac.

## O7. `cctrl approvals check` and a corrected APPROVALS block (step 6; audit option 7)

- **Scope.**
  - `cctrl approvals check <id> [--epoch N] [--now UTC] [--json]`, read-only. It:
    - parses the **whole** record, from `id:` to the next record or the closing fence, never
      a fixed `-A` window;
    - checks the type (grant), and that no later revocation record names it;
    - checks `expires_utc` against the current UTC time, and the session epoch when the
      record names one;
    - prints scope and limits.
  - Exit 0 valid, 1 expired or revoked, 2 not found or malformed.
  - The approvals file path comes from config (`approvals_file`). cctrl does **not** default
    it to any fleet path. The command is generic doctrine, not environment-specific.
  - The APPROVALS block in the four skills is rewritten:
    - use the command (with the `grep` recipe as a fallback, and the record's real length);
    - look for revocations;
    - use `date -u` for now;
    - state which fields to match;
    - a "narrowing" follow-up still needs an id.
  - **Authenticity** (a writer agents cannot imitate) is out of scope, as the audit says.
- **Closes.** M8 (window, revocation, epoch and time errors).
- **Size.** 8 h (P; includes the 3 h for E6's command tests).
- **Risk.** Low. Read-only.
- **Tests.**
  - Parser unit and property tests: long records, an adjacent record not bled into, a
    revocation later in the file, expiry at the boundary, a malformed record, the epoch.
  - A doc-lint test that the skills' block matches the command's usage (plan 121's E6).
- **Rollback.** `git revert`. The skills fall back to the recipe.
- **Depends on.** Nothing.
- **Needs Matthew's yes:** the install on each Mac, and the skills text change (it reaches
  every new worker and the fleet manager's doctrine).

## O12. Ring cap, name routing, ssh host arguments, quoting (step 5)

- **Scope.**
  - **M6, the audit's ring cap.**
    - Count rings per (recipient, sender), and reserve 2 of the recipient's hourly rings for
      push-allowlisted senders, so junk mail cannot burn them.
    - A missing or corrupt ring state reads as at-cap, and doctor reports it.
    - The sender notice no longer suggests "be woken" through `peer say`. It says the mail
      is queued.
  - **M7, the audit's name identity (short-term only).**
    - A server probe that times out reads as "unknown", which refuses the paste and close
      (exit 75), not "not there".
    - `fleet-anchor` and other placeholders are hidden only on the primary server.
    - `rename`, `reconcile-names` and `set-role` name the server they acted on in their
      output.
    - Replies to a recycled name warn when the occupant's `created_at` is after the original
      message.
  - **M11.**
    - `host add` validates the hostname and user (`^[A-Za-z0-9][A-Za-z0-9._-]*$`, no leading
      `-`), and existing `hosts.json` entries are validated on read (a bad one is skipped
      with a warning).
    - Every ssh call puts `--` before the target.
    - A name not known locally that matches more than one host is refused as ambiguous,
      rather than sent to the first match.
  - **L4.**
    - Quote the temp path inside the `run-shell` string.
    - Escape a leading `=` for zsh in the remote `%q` path.
    - `cctrl fleet` strips control characters from remote names.
- **Closes.** M6 (audit), M7 (short-term), M11, L4.
- **Size.** 13 h (P).
- **Risk.** Low. Each change is narrow, and the probe-timeout change can only refuse more.
- **Tests.**
  - Four junk sends from one sender leave the reserved rings; corrupt state reads as cap.
  - A probe timeout refuses the paste.
  - A placeholder named on the second server is visible.
  - A hostile host value `-oProxyCommand=…` is refused at add and skipped on read, and every
    ssh argv has `--` (asserted through plan 121's E8 fake ssh).
  - An ambiguous host is refused.
  - A leading `=` survives zsh on the remote fake.
- **Rollback.** The previous release. Ring state files are versioned. Old code reads the new
  per-sender file as a missing state and treats it as zero, which is today's behaviour.
- **Depends on.** Plan 116's A0. E8's fake ssh is useful but not required; a minimal stub is
  enough.
- **Needs Matthew's yes:** the install on each Mac.

## Size summary

| Phase | h | Step |
|---|---|---|
| O5 | 8 | 5 |
| O6a | 6 | 5 |
| O12 | 13 | 5 |
| O7 | 8 | 6 |
| O6b | 12 | 8 |
| **Total** | **47** | |

## Out of scope

- Stable peer identity (plans 028/029/034): the real fix for M7.
- Approvals authenticity: a signed writer, or a file owned by another user.
- A bracketed-paste breakout on older tmux servers. tmux 3.8's `paste-buffer` already
  rewrites ESC (audit M3). The running servers' versions are checked by `peer doctor` (O5
  adds a row) rather than patched around.
