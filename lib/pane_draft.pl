#!/usr/bin/perl
# Exit 0 when an escaped pane capture (tmux capture-pane -e) shows a composer
# holding typed text: a prompt glyph ('>' or '❯') followed by at least one
# non-space character drawn outside dim (SGR 2) and outside reverse video
# (SGR 7, the cursor). Claude Code draws its predicted next prompt as dimmed
# ghost text; that is not a draft (plan 073). Exit 1 when a composer was
# found but is empty. Exit 2 when no composer could be found at all — a
# bash-mode `!` prompt, a pager, or a shell left after a crash (plan 086);
# callers already treat any rc other than 0/1 as unverifiable and fail safe.
#
# The composer is scoped to the CURRENT block only: the pane between the last
# two border-only lines in the capture (the box or plain-dash divider Claude
# Code draws around the composer). This is what lets a stale submitted "❯
# ..." line higher up in scrollback (or, worse, above an unrelated bash-mode
# "!" prompt with no glyph at all) stay out of the judgement — plan 073 only
# handled "last glyph line wins", which still misreads a glyph-less current
# composer as the old glyph line above it. Every line inside that block is
# judged (plan 086: wrapped and multi-line drafts), not just the first.
use strict;
use warnings;
use utf8;
use File::Basename qw(dirname);
binmode STDIN, ':encoding(UTF-8)';

our $ANSI_ESCAPE_RE;
do(dirname(__FILE__) . '/ansi_escape.pl') or die "pane_draft.pl: can't load ansi_escape.pl: " . ($@ || $!) . "\n";

my $BORDER  = qr/[╭╮╰╯│─━┄┈┌┐└┘]/;      # box/divider drawing characters
my $SEP     = qr/[\s\x{00A0}]/;          # whitespace, including NBSP
my $LEAD    = qr/(?:$SEP|$BORDER)/;      # a composer line's left margin
my $GLYPH   = qr/[>❯]/;

# Placeholder/hint text only when it IS the composer text, i.e. at its start:
# a typed draft may well contain "for commands" or "lib/ for" (review P2).
# Only applied to a composer line with NO escape sequences at all (plan 086,
# review P3): both production callers pass an escaped capture, where a real
# placeholder is dim and already excluded by the dim check below, so this
# string match is only needed (and only safe) for a plain capture that can't
# show dimness at all.
my $hint = qr/^$LEAD*$GLYPH$SEP*(?:Try "|\? for shortcuts|esc to (?:interrupt|cancel))/i;

# A line that is ENTIRELY border/divider drawing (plus margin whitespace) —
# the top/bottom of the composer's box, or a plain "────" divider line.
my $border_only = qr/^$SEP*$BORDER+$SEP*$/;

sub parse_line {
    # Walk one raw (possibly escaped) line, tracking SGR dim (2) / reverse (7)
    # state. Returns ($visible, $real) of equal length: $visible is the line
    # with all escape sequences removed; $real has a '1' at each position
    # whose character was drawn outside both dim and reverse, '0' otherwise.
    my ($line) = @_;
    my ($dim, $rev) = (0, 0);
    my ($visible, $real) = ('', '');
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
        if (substr($line, $pos) =~ /^$ANSI_ESCAPE_RE/) {
            $pos += length $&;    # other escape sequences carry no text
            next;
        }
        my $ch = substr($line, $pos, 1);
        $pos++;
        $visible .= $ch;
        $real .= (!$dim && !$rev) ? '1' : '0';
    }
    return ($visible, $real);
}

sub has_real_content {
    # True when some character from $start onward in $visible was drawn for
    # real (per $real) and isn't itself whitespace/border filler.
    my ($visible, $real, $start) = @_;
    for my $i ($start .. length($visible) - 1) {
        next unless substr($real, $i, 1) eq '1';
        my $c = substr($visible, $i, 1);
        return 1 if $c !~ /^(?:$SEP|$BORDER)$/;
    }
    return 0;
}

my @raw;
while (my $line = <STDIN>) { chomp $line; push @raw, $line }

my (@visible, @real, @is_border, @is_glyph, @has_esc);
for my $line (@raw) {
    my ($v, $r) = parse_line($line);
    push @visible, $v;
    push @real, $r;
    push @is_border, ($v =~ $border_only) ? 1 : 0;
    push @is_glyph, ($v =~ /^$LEAD*$GLYPH/) ? 1 : 0;
    push @has_esc, ($line =~ /\e/) ? 1 : 0;
}

# Scope to the CURRENT composer block: between the last two border-only
# lines, if there are at least two. With fewer, fall back to whichever side
# of a single border is non-empty, and with none at all (a bare test string,
# or truly no composer chrome anywhere) fall back to the last glyph line
# through EOF, matching the pre-086 behaviour for that minimal shape.
my @border_idx = grep { $is_border[$_] } 0 .. $#raw;
my ($start, $end);
if (@border_idx >= 2) {
    $start = $border_idx[-2] + 1;
    $end   = $border_idx[-1] - 1;
} elsif (@border_idx == 1) {
    # Only one border in view (the capture window cut off its partner) — the
    # composer could be on either side. Prefer whichever side actually has a
    # glyph line: picking "after" unconditionally lost a real draft when the
    # capture was cut so the composer's TOP border scrolled out, leaving
    # [draft content][bottom border][footer] — "after" is just the footer.
    my $b = $border_idx[0];
    my ($aft_s, $aft_e) = ($b + 1, $#raw);
    my ($bef_s, $bef_e) = (0, $b - 1);
    my $aft_ok = $aft_s <= $aft_e;
    my $bef_ok = $bef_s <= $bef_e;
    # Tighten to the LAST glyph line within the chosen side, same as the
    # zero-border fallback below, not the side's whole boundary: a "before"
    # side in particular can span the entire scrollback above a composer
    # that never draws a top rule, and scanning from index 0 for the FIRST
    # glyph line picks up an unrelated earlier "❯ ..." line from history,
    # then judges everything after it as composer content (regression found
    # 2026-09-29, plan 086 hotfix).
    my @aft_glyph_idx = $aft_ok ? (grep { $is_glyph[$_] } $aft_s .. $aft_e) : ();
    my @bef_glyph_idx = $bef_ok ? (grep { $is_glyph[$_] } $bef_s .. $bef_e) : ();
    if (@aft_glyph_idx) { ($start, $end) = ($aft_glyph_idx[-1], $aft_e) }
    elsif (@bef_glyph_idx) { ($start, $end) = ($bef_glyph_idx[-1], $bef_e) }
    elsif ($aft_ok) { ($start, $end) = ($aft_s, $aft_e) }
    elsif ($bef_ok) { ($start, $end) = ($bef_s, $bef_e) }
    else { ($start, $end) = (1, 0) }
} else {
    # No border-drawing anywhere at all: no structural evidence either way, so
    # this keeps the pre-086 contract exactly rather than newly claiming "no
    # composer found" — that determination needs at least one border-only
    # line as evidence there was ever a composer box to look inside (the
    # real-world "no composer" shapes plan 086 targets, like a bash-mode "!"
    # prompt, still draw a divider around the prompt row; see
    # pane-bashmode-with-history.txt). Without any border, a bare string with
    # no glyph either (a minimal test fixture, or genuinely unrecognizable
    # content) reads as a confirmed-empty composer, exactly as before.
    my @glyph_idx = grep { $is_glyph[$_] } 0 .. $#raw;
    if (@glyph_idx) { $start = $glyph_idx[-1]; $end = $#raw }
    else { exit(1) }
}

exit(2) if $start > $end;    # no composer content in the capture at all

my $glyph_line;
for my $i ($start .. $end) {
    if ($is_glyph[$i]) { $glyph_line = $i; last }
}
exit(2) unless defined $glyph_line;    # bordered block, no composer prompt in it

my $found = 0;
for my $i ($glyph_line .. $end) {
    next if $is_border[$i];    # shouldn't occur inside a well-formed block
    if ($i == $glyph_line) {
        next if !$has_esc[$i] && $visible[$i] =~ $hint;
        my ($prefix) = $visible[$i] =~ /^($LEAD*$GLYPH)/;
        $found = 1 if has_real_content($visible[$i], $real[$i], length($prefix // ''));
    } else {
        $found = 1 if has_real_content($visible[$i], $real[$i], 0);
    }
}

exit($found ? 0 : 1);
