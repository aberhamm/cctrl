#!/usr/bin/env perl
# Strip all escape sequences from stdin. Shared regex with lib/pane_draft.pl
# via lib/ansi_escape.pl (plan 086) so cctrl's _strip_sgr can't drift from the
# detector's own idea of what an escape sequence is.
use strict;
use warnings;
use utf8;
use File::Basename qw(dirname);
binmode STDIN, ':encoding(UTF-8)';
binmode STDOUT, ':encoding(UTF-8)';

our $ANSI_ESCAPE_RE;
do(dirname(__FILE__) . '/ansi_escape.pl') or die "strip_ansi.pl: can't load ansi_escape.pl: " . ($@ || $!) . "\n";

while (my $line = <STDIN>) {
    $line =~ s/$ANSI_ESCAPE_RE//g;
    print $line;
}
