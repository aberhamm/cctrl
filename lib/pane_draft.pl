#!/usr/bin/perl
# Exit 0 when an escaped pane capture (tmux capture-pane -e) shows a composer
# line with typed text: a prompt glyph ('>' or '❯') followed by at least one
# non-space character drawn outside dim (SGR 2) and outside reverse video
# (SGR 7, the cursor). Claude Code draws its predicted next prompt as dimmed
# ghost text; that is not a draft (plan 073). Only the LAST prompt line is
# judged: it is the composer. Earlier "❯ yes" lines are submitted messages in
# the transcript above it.
use strict;
use warnings;
use utf8;
binmode STDIN, ':encoding(UTF-8)';

my $hint = qr/Try "|for shortcuts|for commands|for newline|esc to (?:interrupt|cancel)|\/ for/i;
my $found = 0;
while (my $line = <STDIN>) {
    chomp $line;
    my ($dim, $rev) = (0, 0);
    my ($visible, $typed) = ('', '');
    my $pos = 0;
    while ($pos < length $line) {
        if (substr($line, $pos) =~ /^\e\[([0-9;]*)m/) {
            my @codes = length $1 ? split(/;/, $1) : (0);
            for (my $i = 0; $i < @codes; $i++) {
                my $c = $codes[$i];
                if ($c eq '' || $c == 0) { ($dim, $rev) = (0, 0) }
                elsif ($c == 2) { $dim = 1 }
                elsif ($c == 22) { $dim = 0 }
                elsif ($c == 7) { $rev = 1 }
                elsif ($c == 27) { $rev = 0 }
                elsif ($c == 38 || $c == 48 || $c == 58) {
                    # Extended colour: skip its parameters.
                    $i += ($codes[$i + 1] // '') eq '5' ? 2 : ($codes[$i + 1] // '') eq '2' ? 4 : 0;
                }
            }
            $pos += length $&;
            next;
        }
        if (substr($line, $pos) =~ /^\e(?:\[[0-9;?]*[A-Za-z]|\][^\a]*\a|.)/) {
            $pos += length $&;    # other escape sequences carry no text
            next;
        }
        my $ch = substr($line, $pos, 1);
        $pos++;
        $visible .= $ch;
        # Text after the glyph counts only when drawn normally.
        $typed .= $ch if $visible =~ /^[\s\x{00A0}│|]*[>❯]./ && !$dim && !$rev;
    }
    next unless $visible =~ /^[\s\x{00A0}│|]*[>❯]/;
    if ($visible =~ $hint) { $found = 0; next }
    $typed =~ s/^[\s\x{00A0}│|]*[>❯]//;
    $found = ($typed =~ /[^\s\x{00A0}│|]/) ? 1 : 0;
}
exit($found ? 0 : 1);
