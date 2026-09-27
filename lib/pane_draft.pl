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

# Placeholder/hint text only when it IS the composer text, i.e. at its start:
# a typed draft may well contain "for commands" or "lib/ for" (review P2).
my $hint = qr/^[\s\x{00A0}│|]*[>❯][\s\x{00A0}]*(?:Try "|\? for shortcuts|esc to (?:interrupt|cancel))/i;
my $found = 0;
while (my $line = <STDIN>) {
    chomp $line;
    my ($dim, $rev) = (0, 0);
    my ($visible, $typed) = ('', '');
    my $pos = 0;
    while ($pos < length $line) {
        if (substr($line, $pos) =~ /^\e\[([0-9;:]*)m/) {
            my @codes = length $1 ? split(/;/, $1) : (0);
            for (my $i = 0; $i < @codes; $i++) {
                my $c = $codes[$i];
                $c =~ s/:.*//;    # colon sub-parameters, e.g. 4:3 curly underline
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
        if (substr($line, $pos) =~ /^\e(?:\[[0-9;:?<>=]*[ -\/]*[\@-~]|\].*?(?:\a|\e\\)|.)/) {
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
