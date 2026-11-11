---
id: 119
title: Overhaul O5-O12 - envelope, timestamps and env overrides, pane targeting, approvals check, ring cap, names, remote hosts
status: blocked
blocked-by: [115]
priority: 14
allows-migrations: false
needs-review: eng
review-required: eng
created: 2026-11-11
approval: "Operator approval on record (plan-only grant): PLAN ONLY. Run per phase under the orchestrator; never flip this plan to pending as a whole. Waits for Matthew's prioritisation from plan 115. Every install needs its own yes; O7 also changes skills text."
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

**Phase ids.** O5-O7 follow the audit's option numbers. **O12 is not an audit option** (the
audit has options 1-11, and option 11, "accept the risk", is rejected in plan 115). O12 is
this plan's name for the leftover items M6, M7, M11 and L4; O8-O11 are not used here because
options 8-10 map to plans 117, 116 and 120.

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
  - **M5 and SH-S6.** One test-mode gate, `_cctrl_test_mode`. **It now ships in plan 116's
    A0** (review S10), so A1's fault-injection variable is gated from its first release. The
    property it guarantees is not "a marker agents cannot reach" (an agent can make its own
    sandbox): it is that overrides only take effect when **every** state path, and the seal
    key path, resolves inside one sandbox holding `.cctrl-test-sandbox`, and test mode
    refuses the live seal key. A sandbox with no live store and no live key cannot mint
    anything the live store would accept. O5 wires the remaining users to that gate.

    Outside test mode, the attest path ignores `CCTRL_NOW_UTC`, the fault-injection variables
    (plan 116), plan 120's B4 tool-path override, the login-root override and the `sudo`
    stub (plan 118), and
    records `env_override` when `CCTRL_SESSION_METADATA_DIR`, `TMUX_TMPDIR` or
    `CCTRL_TMUX_EXTRA_SERVERS` differ from the resolver defaults. The class cap itself is in
    plan 118.
  - **The paste sanitising cctrl relies on.** `peer doctor` gains a row with each running tmux
    server's version, and warns below 3.8, where `paste-buffer` may not rewrite ESC (audit
    handoff, item 2).
- **Closes.** M3, M4, M5 (the env half; plan 118 does the tool-path half), SH-S6 (the gate
  that B4 reuses).
- **Size.** 7 h (P; was 8, with 1 h moved to plan 116's A0 with the gate).
- **Risk.** Low. The human output format changes; scripts use `--json`.
- **Tests.**
  - Hostile subjects are refused: LF, CR, ESC, NUL, a forged header.
  - A body containing a fake `[cctrl peer message] from: peer-x · verified` line and a
    fake fence renders inside the real fence.
  - Display stripping on the human paths.
  - `CCTRL_NOW_UTC` is ignored outside test mode, and the name-recycle guard holds.
  - Every override listed above is ignored outside test mode (the gate's own tests are in
    plan 116's A0).
  - Plan 121's E4 expected failures for M3 and M4 flip to passing.
- **Rollback.** The previous release. Stored messages are unchanged.
- **Blocked by.** Plan 116's A0 (the test-mode gate). Plan 121's E4 should land first.
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
- **Blocked by.** O3.1 (so say is logged when the targeting changes). Independent of plan
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
- **Blocked by.** Plan 120's B6, plan 121's E10, and O6a.
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
- **Size.** 8 h (P). It includes the command's own parser and property tests. Plan 121's E6
  (3 h) is separate: the doc-lint that the skills' block matches the command. No double
  count.
- **Risk.** Low. Read-only.
- **Tests.**
  - Parser unit and property tests: long records, an adjacent record not bled into, a
    revocation later in the file, expiry at the boundary, a malformed record, the epoch.
  - A doc-lint test that the skills' block matches the command's usage (plan 121's E6).
- **Rollback.** `git revert`. The skills fall back to the recipe.
- **Blocked by.** Nothing.
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
    - **Deferred, with reason (review S16):** tying the push allowlist to a session's
      creation time. Allowlist entries carry no time today, so it needs a doorbell.json
      shape change (a frozen interface) and belongs with stable identity (plans
      028/029/034). Until then the reply warning above and the doctor row cover recycled
      names.
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
- **Blocked by.** Plan 116's A0. E8's fake ssh is useful but not required; a minimal stub is
  enough.
- **Needs Matthew's yes:** the install on each Mac.

## Size summary

| Phase | h | Step |
|---|---|---|
| O5 | 7 | 5 |
| O6a | 6 | 5 |
| O12 | 13 | 5 |
| O7 | 8 | 6 |
| O6b | 12 | 8 |
| **Total** | **46** | was 47; 1 h moved to plan 116's A0 |

## Execution and acceptance criteria

- **Execution.** Run per phase under the orchestrator: O5, O6a and O12 at step 5 (which may
  start once plan 116's A0 and A1 are done), O7 at step 6, O6b at step 8 after plan 120's B6.
  Never flip this plan to `pending` as a whole. The frontmatter `blocked-by: [115]` is a
  guard (115 stays `split`).
- [ ] O5: hostile subjects are refused; a forged header and fence in a body render inside the
  real fence; `CCTRL_NOW_UTC` and every other override are ignored outside test mode; plan
  121's E4 cases for M3 and M4 pass.
- [ ] O6a: with a split pane, the paste lands only in the agent pane; two agent panes are
  refused with exit 75.
- [ ] O6b: a modal raised between check and Enter withholds the Enter; a timed-out client is
  `unknown`.
- [ ] O7: `approvals check` parses whole records, honours revocations, expiry and epoch, and
  the skills' block matches it (E6).
- [ ] O12: junk senders cannot burn the reserved rings; corrupt ring state reads as cap; a
  probe timeout refuses; hostile host values are refused and every ssh argv has `--`.

## Out of scope

- Stable peer identity (plans 028/029/034): the real fix for M7.
- Approvals authenticity: a signed writer, or a file owned by another user.
- A bracketed-paste breakout on older tmux servers. tmux 3.8's `paste-buffer` already
  rewrites ESC (audit M3). The running servers' versions are checked by `peer doctor` (O5
  adds a row) rather than patched around.
