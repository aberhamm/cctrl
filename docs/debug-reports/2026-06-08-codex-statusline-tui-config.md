# Debug Report: Codex Statusline TUI Config

Date: 2026-06-08
Status: DONE

## Symptom

After running `cctrl statusline codex install` and restarting Codex, the expected
status line still did not appear. `cctrl statusline codex show` reported:

```text
not configured
```

## Root Cause

`cctrl` originally installed and read the Codex statusline setting as:

```toml
[tui]
status_line = [...]
```

During debugging, a top-level setting was tried:

```toml
status_line = [...]
```

That was the wrong inference. Codex 0.137 parses the top-level key without
failing, but the TUI ignores it for rendering. A live tmux reproduction confirmed
the effective config path is still `[tui].status_line`:

```bash
codex -c 'tui.status_line=["run-state","git-branch","current-dir","model-with-reasoning"]'
```

This changed the visible footer immediately, while:

```bash
codex -c 'status_line=["run-state","git-branch","current-dir","model-with-reasoning"]'
```

left the default footer unchanged.

## Fix

Updated `cctrl statusline codex install` to:

- replace or insert `[tui].status_line`;
- preserve existing tables such as `[tui.model_availability_nux]`;
- remove ignored top-level `status_line` entries during migration.

Updated `cctrl statusline codex show` to report only the effective
`[tui].status_line` setting. If only a top-level setting exists, it now reports
that the top-level key is ignored rather than falsely treating it as configured.

## Regression Test

Added `test_codex_statusline_tui_config` in `tests/run-tests.sh`. It uses a
temporary `CODEX_HOME` containing an ignored top-level `status_line` plus
`[tui.model_availability_nux]`, runs the installer, and verifies that:

- `[tui].status_line` is present;
- `[tui.model_availability_nux]` is preserved;
- the ignored top-level `status_line` is removed;
- `cctrl statusline codex show` reads back the effective `[tui]` setting.

## Verification

```bash
tests/run-tests.sh
```

Result:

```text
ok
```

Applied the fixed installer to the real Codex config:

```bash
./cctrl statusline codex install
./cctrl statusline codex show
```

Readback:

```text
status_line = ["model-with-reasoning", "context-remaining", "context-used", "git-branch", "current-dir", "run-state"]
```

Live TUI verification in a throwaway tmux session showed the configured footer:

```text
gpt-5.5 xhigh · Context 100% left · Context 0% used · main · ~/dev/projects/cctrl · Starting
```
