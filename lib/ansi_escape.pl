# Shared escape-sequence regex used by lib/pane_draft.pl (per-char SGR-state
# walk) and lib/strip_ansi.pl (bulk strip, backing cctrl's _strip_sgr), so the
# two definitions of "what counts as an escape sequence" can't drift (plan
# 086). Matches one full CSI sequence (with intermediates, e.g. colon SGR
# sub-parameters), one OSC sequence terminated by BEL or ST, or any other
# single ESC + byte.
our $ANSI_ESCAPE_RE = qr/\e(?:\[[0-9;:?<>=]*[ -\/]*[\@-~]|\].*?(?:\a|\e\\)|.)/;
1;
