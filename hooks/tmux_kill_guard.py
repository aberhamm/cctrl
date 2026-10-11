#!/usr/bin/env python3
"""Pure parser behind the PreToolUse tmux guard (docs/plans/107).

`check_command(text)` answers one question about a shell command line: would
it run `tmux kill-server` against a server that the same tmux invocation does
not name with `-S <path>` or `-L <name>`? It returns a short reason when it
would, and None otherwise. `hooks/pre-tool-use.py` turns a reason into the
hook protocol's deny (exit 2).

Why: tmux prefers `$TMUX` over `TMUX_TMPDIR`, and every shell inside a tmux
pane (a sub-agent's too) inherits `$TMUX`. A bare `tmux kill-server` there
kills the server the session itself runs on. On 2026-10-09 one such cleanup
line killed a whole fleet (docs/findings/tmux-untargeted-default-server.md).

This is an accident guard, not a security boundary. It reads the command
text only: it starts nothing, opens no file and never calls tmux. A script
written to a file and run later, or a command hidden behind a function or a
variable set in an earlier call, is out of its reach. When the parse is
uncertain it prefers to block (see the plan for the list).
"""

from __future__ import annotations

import re

MAX_DEPTH = 6
MAX_LEN = 200_000

# tmux accepts any unambiguous prefix of a command name. "kill-s" is ambiguous
# (kill-session), so the shortest form that means kill-server is "kill-ser".
_KILL = r"kill-ser(?:v(?:e(?:r)?)?)?"
KILL_RE = re.compile(r"(?<![\w-])" + _KILL + r"(?![\w-])")
TMUX_RE = re.compile(r"(?<![\w.-])tmux(?![\w.-])")
_SOCK_FLAG_RE = re.compile(r"(?<!\S)-[0-9A-Za-z]*[SL]")
_ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(?:\[[^\]]*\])?\+?=")
_ANSI_NUM_RE = re.compile(r"x([0-9A-Fa-f]{1,2})|u([0-9A-Fa-f]{1,4})|([0-7]{1,3})")
_PYTHON_RE = re.compile(r"^python[0-9.]*$")
_INHERITED_SOCK_RE = re.compile(r"\$\{?TMUX(?![A-Za-z0-9_])|socket_path")
_DEFAULT_SOCK_RE = re.compile(r"^(?:/private)?/tmp/tmux-[^/]+/default$")
_ANSI_SIMPLE = {
    "n": "\n", "t": "\t", "\\": "\\", "'": "'", '"': '"', "a": "\a",
    "b": "\b", "e": "\x1b", "f": "\f", "r": "\r", "v": "\v",
}

# Shell words that sit in front of a command without being one.
RESERVED = frozenset({"if", "then", "elif", "else", "do", "while", "until", "!", "{", "time", "coproc"})
# Commands whose arguments are text or word lists, never a command to run.
TEXT_HEADS = frozenset({
    "echo", "printf", "grep", "egrep", "fgrep", "rg", "ag", "ack", "git", "gh",
    "cat", "bat", "less", "more", "head", "tail", "wc", "sed", "awk", "gawk",
    "jq", "yq", "man", "tldr", "which", "whence", "type", "whereis", "apropos",
    "ls", "test", "[", "[[", ":", "true", "false", "cd", "pushd", "popd",
    "read", "export", "declare", "local", "typeset", "readonly", "unset",
    "basename", "dirname", "diff", "cmp", "touch", "mkdir", "rmdir", "rm",
    "cp", "mv", "ln", "tee", "sort", "uniq", "cut", "tr", "pgrep", "ps",
    "for", "case", "select", "return", "exit", "sleep", "wait",
})
# Prefix commands that run the rest of their arguments as a command.
WRAPPERS = frozenset({
    "command", "builtin", "exec", "nohup", "nice", "sudo", "doas",
    "caffeinate", "stdbuf", "setsid", "noglob", "nocorrect", "chronic",
})
SHELLS = frozenset({"sh", "bash", "zsh", "dash", "ksh", "mksh", "ash", "fish", "csh", "tcsh"})
# Commands that run a string argument as code (in a shell or in their own
# language). A string argument that mentions the kill is scanned as shell text.
EXEC_HEADS = frozenset({
    "ssh", "mosh", "su", "osascript", "watch", "xargs", "find", "parallel",
    "at", "batch", "script", "expect", "timeout", "gtimeout", "flock", "perl",
    "ruby", "node", "deno", "bun", "php", "lua", "env",
})


def _dequote(text):
    return re.sub(r"[\\'\"]", "", text.replace("\\\n", ""))


def _mentions_kill(text):
    return "kill-ser" in _dequote(text)


def _loose(text):
    """Regex fallback for text that is not parsed as shell (another language's
    code, a parse that failed or nested too deep). True when a tmux word is
    followed by the kill with no -S/-L token between them."""
    flat = _dequote(text)
    marks = [m.start() for m in TMUX_RE.finditer(flat)]
    for n, start in enumerate(marks):
        end = marks[n + 1] if n + 1 < len(marks) else len(flat)
        region = flat[start:end]
        kill = KILL_RE.search(region)
        if kill and not _SOCK_FLAG_RE.search(region[:kill.start()]):
            return True
    return False


class _Word:
    __slots__ = ("text", "literal", "plain", "assign")

    def __init__(self, text, literal, plain, assign):
        self.text = text        # best-effort value; expansions stay as written ($X)
        self.literal = literal  # no expansion or substitution inside
        self.plain = plain      # no quoting, escape or expansion at all
        self.assign = assign    # NAME=value form


class _Cmd:
    __slots__ = ("words", "stdin", "prev")

    def __init__(self, prev=None):
        self.words = []
        self.stdin = []   # here-document bodies and here-strings
        self.prev = prev  # the pipeline stage that feeds this one


def _match(s, i, opener, closer):
    """Index of the closer that matches the opener at s[i], or len(s)."""
    depth = 0
    n = len(s)
    k = i
    while k < n:
        c = s[k]
        if c == "\\":
            k += 2
            continue
        if c == "'":
            e = s.find("'", k + 1)
            k = n if e < 0 else e + 1
            continue
        if c == '"':
            k += 1
            while k < n and s[k] != '"':
                k += 2 if s[k] == "\\" else 1
            k += 1
            continue
        if c == opener:
            depth += 1
        elif c == closer:
            depth -= 1
            if depth == 0:
                return k
        k += 1
    return n


class _Lexer:
    """Splits shell text into simple commands. Command and process
    substitutions are collected in `subs` for the caller to check as shell
    text of their own."""

    def __init__(self, src):
        self.s = src
        self.n = len(src)
        self.subs = []
        self.cmds = []
        self.cur = _Cmd()
        self.pending = []  # here-documents whose bodies start after the next newline
        self.last_end = -1

    def _end(self, pipe=False):
        done = self.cur
        self.cmds.append(done)
        self.cur = _Cmd(done if pipe else None)

    def run(self):
        s, n = self.s, self.n
        i = 0
        while i < n:
            c = s[i]
            nx = s[i + 1] if i + 1 < n else ""
            if c in " \t\r":
                i += 1
            elif c == "\\" and nx == "\n":
                i += 2
            elif c == "\n":
                self._end()
                i += 1
                if self.pending:
                    i = self._heredocs(i)
            elif c == "#":
                j = s.find("\n", i)
                i = n if j < 0 else j
            elif c == ";":
                self._end()
                i += 1
            elif c == "&":
                if nx == ">":
                    i = self._redirect(i)
                elif nx == "&":
                    self._end()
                    i += 2
                else:
                    self._end()
                    i += 1
            elif c == "|":
                if nx == "|":
                    self._end()
                    i += 2
                elif nx == "&":
                    self._end(True)
                    i += 2
                else:
                    self._end(True)
                    i += 1
            elif c in "()":
                self._end()
                i += 1
            elif c in "<>":
                if nx == "(":
                    j = _match(s, i + 1, "(", ")")
                    self.subs.append(s[i + 2:j])
                    self.cur.words.append(_Word(s[i:j + 1], False, False, False))
                    i = j + 1
                else:
                    i = self._redirect(i)
            else:
                word, i = self._word(i)
                self.cur.words.append(word)
                self.last_end = i
        self._end()
        return self.cmds, self.subs

    def _redirect(self, i):
        s, n = self.s, self.n
        words = self.cur.words
        if words and self.last_end == i and words[-1].plain and words[-1].text.isdigit():
            words.pop()  # the fd number of 2>file
        op = ""
        for op in ("&>>", "&>", "<<<", "<<-", "<<", "<>", "<&", ">>", ">&", ">|", "<", ">"):
            if s.startswith(op, i):
                break
        i += len(op)
        while i < n and s[i] in " \t":
            i += 1
        if i >= n or s[i] in "\n;&|()<>":
            return i
        target, i = self._word(i)
        if op in ("<<", "<<-"):
            self.pending.append((target.text, op == "<<-", not target.plain, self.cur))
        elif op == "<<<":
            self.cur.stdin.append(target.text)
        return i

    def _heredocs(self, i):
        s, n = self.s, self.n
        for delim, strip, quoted, cmd in self.pending:
            lines = []
            while i < n:
                j = s.find("\n", i)
                if j < 0:
                    j = n
                line = s[i:j]
                i = min(j + 1, n)
                if (line.lstrip("\t") if strip else line) == delim:
                    break
                lines.append(line)
            body = "\n".join(lines)
            cmd.stdin.append(body)
            if not quoted:
                self._nested(body, False)  # an unquoted body still expands $(...)
        self.pending = []
        return i

    def _nested(self, text, squote):
        """Collect $(...) and `...` from text that is not split into words
        (a ${...} expansion, an unquoted here-document body)."""
        k = 0
        m = len(text)
        while k < m:
            c = text[k]
            if c == "\\":
                k += 2
                continue
            if squote and c == "'":
                e = text.find("'", k + 1)
                k = m if e < 0 else e + 1
                continue
            if c == "$" and text.startswith("$(", k):
                j = _match(text, k + 1, "(", ")")
                self.subs.append(text[k + 2:j])
                k = j + 1
                continue
            if c == "`":
                e = text.find("`", k + 1)
                if e < 0:
                    e = m
                self.subs.append(text[k + 1:e])
                k = e + 1
                continue
            k += 1

    def _backtick(self, i, buf):
        s, n = self.s, self.n
        e = i + 1
        while e < n and s[e] != "`":
            e += 2 if s[e] == "\\" else 1
        self.subs.append(s[i + 1:e].replace("\\`", "`"))
        buf.append(s[i:e + 1])
        return e + 1

    def _dollar(self, i, buf):
        """At s[i] == '$'. Returns (next index, still literal)."""
        s, n = self.s, self.n
        nx = s[i + 1] if i + 1 < n else ""
        if nx == "(":
            j = _match(s, i + 1, "(", ")")
            self.subs.append(s[i + 2:j])
            buf.append(s[i:j + 1])
            return j + 1, False
        if nx == "{":
            j = _match(s, i + 1, "{", "}")
            self._nested(s[i + 2:j], True)
            buf.append(s[i:j + 1])
            return j + 1, False
        if nx.isalpha() or nx == "_":
            j = i + 2
            while j < n and (s[j].isalnum() or s[j] == "_"):
                j += 1
            buf.append(s[i:j])
            return j, False
        if nx and (nx.isdigit() or nx in "@*#?$!-"):
            buf.append(s[i:i + 2])
            return i + 2, False
        buf.append("$")
        return i + 1, True

    def _dquote(self, i, buf):
        """After an opening double quote. Returns (next index, still literal)."""
        s, n = self.s, self.n
        literal = True
        while i < n:
            c = s[i]
            if c == '"':
                return i + 1, literal
            if c == "\\":
                nx = s[i + 1] if i + 1 < n else ""
                if nx == "\n":
                    i += 2
                elif nx and nx in '$`"\\':
                    buf.append(nx)
                    i += 2
                else:
                    buf.append(c)
                    i += 1
                continue
            if c == "$":
                i, lit = self._dollar(i, buf)
                literal = literal and lit
                continue
            if c == "`":
                i = self._backtick(i, buf)
                literal = False
                continue
            buf.append(c)
            i += 1
        return i, literal

    def _ansi(self, i, buf):
        """After $' : ANSI-C quoting. Returns the next index."""
        s, n = self.s, self.n
        out = []
        while i < n and s[i] != "'":
            if s[i] == "\\" and i + 1 < n:
                e = s[i + 1]
                if e in _ANSI_SIMPLE:
                    out.append(_ANSI_SIMPLE[e])
                    i += 2
                    continue
                m = _ANSI_NUM_RE.match(s, i + 1)
                if m:
                    if m.group(3) is not None:
                        code = int(m.group(3), 8)
                    else:
                        code = int(m.group(1) or m.group(2), 16)
                    out.append(chr(code))
                    i = m.end()
                    continue
                out.append(e)
                i += 2
                continue
            out.append(s[i])
            i += 1
        buf.append("".join(out))
        return i + 1

    def _word(self, i):
        s, n = self.s, self.n
        buf = []
        lead = []  # the leading run of plain characters (finds NAME=)
        literal = True
        plain = True
        while i < n:
            c = s[i]
            if c in " \t\r\n;&|()<>":
                break
            if c == "\\":
                if i + 1 < n and s[i + 1] == "\n":
                    i += 2
                    continue
                if i + 1 < n:
                    buf.append(s[i + 1])
                i += 2
                plain = False
                continue
            if c == "'":
                e = s.find("'", i + 1)
                if e < 0:
                    e = n
                buf.append(s[i + 1:e])
                i = e + 1
                plain = False
                continue
            if c == '"':
                i, lit = self._dquote(i + 1, buf)
                literal = literal and lit
                plain = False
                continue
            if c == "$":
                nx = s[i + 1] if i + 1 < n else ""
                plain = False
                if nx == "'":
                    i = self._ansi(i + 2, buf)
                    continue
                if nx == '"':
                    i += 1
                    continue
                i, lit = self._dollar(i, buf)
                literal = literal and lit
                continue
            if c == "`":
                i = self._backtick(i, buf)
                literal = False
                plain = False
                continue
            buf.append(c)
            if plain:
                lead.append(c)
            i += 1
        return _Word("".join(buf), literal, plain, bool(_ASSIGN_RE.match("".join(lead)))), i


def _base(word):
    """The command name a word stands for, or None when it is an expansion."""
    base = word.text.rsplit("/", 1)[-1]
    if not word.literal and ("$" in base or "`" in base):
        return None
    return base


def _socket_problem(sock_s, sock_l):
    """None when the invocation names a server of its own; else what is wrong."""
    if sock_s is not None:
        text, literal = sock_s
        if text == "" and literal:
            return "-S has an empty path"
        if _INHERITED_SOCK_RE.search(text):
            return "-S resolves to the inherited server ($TMUX / socket_path)"
        if _DEFAULT_SOCK_RE.match(text):
            return "-S names the default server's socket"
        return None
    if sock_l is not None:
        text, literal = sock_l
        if text == "" and literal:
            return "-L has an empty name"
        if text == "default":
            return "-L default names the default server"
        return None
    return "no -S/-L on this tmux invocation"


def _check_tmux(args, cmd, full, strict=False):
    """args: the words after the tmux word. strict: the command name is an
    expansion, so only an explicit kill word counts."""
    sock_s = sock_l = None
    control = False
    i = 0
    while i < len(args):
        arg = args[i]
        text = arg.text
        if text == "--":
            i += 1
            break
        if not text.startswith("-") or text == "-":
            break
        j = 1
        while j < len(text):
            ch = text[j]
            if ch == "C":
                control = True
            if ch in "SLcfT":  # the options that take a value
                value = (text[j + 1:], arg.literal)
                if value[0] == "" and j + 1 >= len(text):
                    if i + 1 < len(args):
                        i += 1
                        value = (args[i].text, args[i].literal)
                    else:
                        value = ("", True)
                if ch == "S":
                    sock_s = value
                elif ch == "L":
                    sock_l = value
                break
            j += 1
        i += 1
    rest = args[i:]
    problem = _socket_problem(sock_s, sock_l)
    if problem is None:
        return None
    at_command = True
    for arg in rest:
        if KILL_RE.search(arg.text):
            return "tmux kill-server: " + problem
        if at_command and not arg.literal and not strict and _mentions_kill(full):
            return ("a tmux command name is a variable and the line mentions kill-server "
                    "(cannot tell them apart): " + problem)
        at_command = arg.text.endswith(";")
    if not strict and (control or not rest):
        for text in _stdin_texts(cmd):
            if KILL_RE.search(_dequote(text)):
                return "kill-server on the standard input of tmux: " + problem
    return None


def _stdin_texts(cmd):
    """Text that reaches the command's standard input, as far as the line
    shows it: its here-documents and the pipeline stages in front of it."""
    out = list(cmd.stdin)
    stage = cmd.prev
    hops = 0
    while stage is not None and hops < 16:
        texts = [w.text for w in stage.words]
        out.extend(texts[1:])
        if len(texts) > 2:
            out.append(" ".join(texts[1:]))
        out.extend(stage.stdin)
        stage = stage.prev
        hops += 1
    return out


def _check_shell(args, cmd, depth, full):
    """args: the words after a shell's name (sh, bash, ...)."""
    j = 0
    while j < len(args):
        arg = args[j]
        text = arg.text
        if arg.literal and len(text) > 1 and text[0] in "-+":
            if text[0] == "-" and not text.startswith("--") and "c" in text[1:]:
                k = j + 1
                while k < len(args) and args[k].literal and args[k].text.startswith("-"):
                    k += 1
                if k < len(args):
                    return _check_text(args[k].text, depth + 1, full)
                return None
            if text in ("-o", "-O", "+o", "+O", "--rcfile", "--init-file"):
                j += 1
            j += 1
            continue
        break
    if j >= len(args) or args[j].text == "-":  # no script file: the script is stdin
        for text in _stdin_texts(cmd):
            reason = _check_text(text, depth + 1, full)
            if reason:
                return reason
    return None


def _check_cmd(cmd, depth, full):
    words = list(cmd.words)
    while words:
        word = words[0]
        if word.assign or (word.plain and word.text in RESERVED):
            words.pop(0)
            continue
        name = _base(word)
        if name in WRAPPERS:
            words.pop(0)
            while words and words[0].literal and words[0].text.startswith("-"):
                words.pop(0)
            continue
        if name == "env":
            words.pop(0)
            while words:
                word = words[0]
                if word.assign:
                    words.pop(0)
                elif word.literal and word.text.startswith("-"):
                    if word.text in ("-S", "--split-string"):
                        return _check_text(" ".join(w.text for w in words[1:]), depth + 1, full)
                    del words[:2 if word.text in ("-u", "-C", "-P", "--unset", "--chdir") else 1]
                else:
                    break
            continue
        break
    if not words:
        return None
    name = _base(words[0])
    if name in TEXT_HEADS:
        return None
    args = words[1:]
    if name == "eval":
        return _check_text(" ".join(w.text for w in args), depth + 1, full)
    if name == "trap":
        for arg in args:
            reason = _check_text(arg.text, depth + 1, full)
            if reason:
                return reason
        return None
    if name == "alias":
        for arg in args:
            reason = _check_text(arg.text.partition("=")[2], depth + 1, full)
            if reason:
                return reason
        return None

    names = [_base(w) for w in words]
    if "tmux" in names:
        # Also when tmux is not the first word: an unknown command in front of
        # it (timeout, xargs, a wrapper script) may run it.
        reason = _check_tmux(words[names.index("tmux") + 1:], cmd, full)
        if reason:
            return reason
    elif name is None and re.search("tmux", full, re.I):
        # `"$TMUX_BIN" kill-server`, `$(command -v tmux) kill-server`.
        reason = _check_tmux(args, cmd, full, strict=True)
        if reason:
            return "the command name is a variable and the line mentions tmux; " + reason
    shell_at = next((n for n, base in enumerate(names) if base in SHELLS), None)
    if shell_at is not None:
        reason = _check_shell(words[shell_at + 1:], cmd, depth, full)
        if reason:
            return reason
    if name in ("ssh", "mosh") and shell_at is None:
        # `ssh host <<EOF`: the remote login shell reads the script from stdin.
        for text in _stdin_texts(cmd):
            reason = _check_text(text, depth + 1, full)
            if reason:
                return reason
    if name in EXEC_HEADS or (name and _PYTHON_RE.match(name)):
        for arg in args:
            if not _mentions_kill(arg.text):
                continue
            reason = _check_text(arg.text, depth + 1, full)
            if reason:
                return reason
            if _loose(arg.text):
                return "a string argument of `%s` runs tmux kill-server without -S/-L" % name
    return None


def _check_text(text, depth, full):
    if depth > MAX_DEPTH:
        return "nested too deep to parse; tmux kill-server without -S/-L" if _loose(text) else None
    cmds, subs = _Lexer(text).run()
    for sub in subs:
        reason = _check_text(sub, depth + 1, full)
        if reason:
            return reason
    for cmd in cmds:
        reason = _check_cmd(cmd, depth, full)
        if reason:
            return reason
    return None


def check_command(command):
    """A reason (str) when the command would run `tmux kill-server` against a
    server its tmux invocation does not name; None when it would not. Never
    raises: a parser error falls back to the regex check."""
    if not isinstance(command, str) or not _mentions_kill(command):
        return None
    try:
        if len(command) > MAX_LEN:
            return "command too long to parse; tmux kill-server without -S/-L" if _loose(command) else None
        return _check_text(command, 0, command)
    except Exception:  # fail open unless the fallback itself is a positive match
        try:
            return "could not parse the command; tmux kill-server without -S/-L" if _loose(command) else None
        except Exception:
            return None


def block_message(reason):
    return (
        "BLOCKED by cctrl (tmux guard): this command would run `tmux kill-server` on a server it does not name.\n"
        "Reason: %s.\n"
        "A bare `tmux kill-server` goes to the server in $TMUX, whatever TMUX_TMPDIR says. Inside a cctrl\n"
        "session that is the server every session of the fleet runs on. One such cleanup line once killed a\n"
        "whole fleet, which is why this guard exists.\n"
        "Do this instead:\n"
        "  - kill only your own sessions, by exact name:  tmux -S \"<your socket>\" kill-session -t '=NAME'\n"
        "  - or kill your own private server:             tmux -S \"<your socket>\" kill-server\n"
        "The socket flag (-S <path>, or -L <name> other than \"default\") must be on the same tmux invocation\n"
        "as kill-server. An environment prefix (TMUX_TMPDIR=..., env -u TMUX) does not count.\n"
        "If the words are only text (a note, a brief, a commit message): pass them as one quoted argument\n"
        "or write them to a file with a quoted here-document (<<'EOF').\n"
    ) % reason
