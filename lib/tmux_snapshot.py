"""Parse a bounded-header tmux inventory without mistaking malformed data for absence."""
import re


def parse_panes(text):
    rows = []
    if not text:
        return rows
    for line in text.removesuffix('\n').split('\n'):
        # Only fixed-grammar values precede the opaque session name. A name
        # containing pipes cannot shift a pane ID/PID into another session.
        fields = line.split('|', 3)
        if (len(fields) != 4
                or re.fullmatch(r'%[0-9]+', fields[0]) is None
                or re.fullmatch(r'[1-9][0-9]*', fields[1]) is None
                or fields[2] not in ('0', '1') or not fields[3]):
            raise ValueError('malformed-tmux-pane-snapshot')
        rows.append({'pane_id': fields[0], 'pane_pid': fields[1],
                     'current_command': 'codex' if fields[2] == '1' else '',
                     'session': fields[3]})
    return rows
