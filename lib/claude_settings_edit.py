#!/usr/bin/env python3
"""Safe read-modify-write of a Claude Code settings.json, shared by `peer setup`,
`hooks install` and `statusline claude install`.

The implementation lives in claude_inbound.edit_settings (lock, same-directory
fsynced temp file, exact-bytes backup, os.replace, changed-under-us retry).
Invalid JSON is refused, never read as {}. Standard library only.
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from claude_inbound import SettingsError, edit_settings  # noqa: E402,F401
