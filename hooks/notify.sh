#!/usr/bin/env bash
# Usage: notify.sh <stop|notification>
# Called by Claude Code hooks. Reads JSON from stdin.
#
# Intentionally silent. This script used to play an afplay chime and a spoken
# `say` line for done / needs-input / needs-permission. Matthew removed those
# sounds from cctrl itself (2026-11-10), so no install can bring them back.
# The entry point stays so existing hook registrations (`cctrl hooks run
# stop|notify`, legacy `notify.sh stop|notification`) keep working; it drains
# stdin and exits 0.

cat >/dev/null
exit 0
