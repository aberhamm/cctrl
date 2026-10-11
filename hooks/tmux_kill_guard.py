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
MAX_STEPS = 400  # texts checked per command; beyond it the regex check decides

# tmux accepts any unambiguous prefix of a command name. "kill-s" is ambiguous
# (kill-session), so the shortest form that means kill-server is "kill-ser".
_KILL = r"kill-ser(?:v(?:e(?:r)?)?)?"
KILL_RE = re.compile(r"(?<![\w-])" + _KILL + r"(?![\w-])")
TMUX_RE = re.compile(r"(?<![\w.-])tmux(?![\w.-])")
_SOCK_FLAG_RE = re.compile(r"(?<![\w$-])-[0-9A-Za-z]*[SL]")
_ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(?:\[[^\]]*\])?\+?=")
_ANSI_NUM_RE = re.compile(r"x([0-9A-Fa-f]{1,2})|u([0-9A-Fa-f]{1,4})|([0-7]{1,3})")
_PYTHON_RE = re.compile(r"^python[0-9.]*$")
_INHERITED_SOCK_RE = re.compile(r"\$\{?TMUX(?![A-Za-z0-9_])|socket_path")
_DEFAULT_SOCK_RE = re.compile(r"/tmp\}?/tmux-[^/]+/default$")
_DEFAULT_SOCK_DIR_RE = re.compile(r"/tmp\}?/tmux-")
_HEREDOC_WORD_RE = re.compile(r"[A-Za-z_]")
_SHELL_VAR_RE = re.compile(r"^\$\{?(?:SHELL|BASH|ZSH_NAME|ZSH)\b")
_VAR_RE = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)")
_HEREDOC_OPEN_RE = re.compile(r"<<(-?)[ \t]*((?:\\|'|\")?[A-Za-z_][A-Za-z0-9_]*['\"]?)")
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
    "timeout", "gtimeout", "flock",
})
# Their options that take a separate value, and those with one operand
# (a duration, a lock file) in front of the command.
WRAPPER_VALUE_OPTS = {
    "sudo": "ughpCDRTUrt", "doas": "uC", "nice": "n", "exec": "a",
    "timeout": "ks", "gtimeout": "ks", "flock": "wEc",
}
WRAPPER_OPERAND = frozenset({"timeout", "gtimeout", "flock"})
SHELLS = frozenset({"sh", "bash", "zsh", "dash", "ksh", "mksh", "ash", "fish", "csh", "tcsh"})
# Commands that hand a string argument to a shell: the string is parsed as
# shell text.
SHELL_STRING_HEADS = frozenset({"ssh", "mosh", "su", "watch", "parallel", "at", "batch", "script"})
# Commands that run a string argument, or their standard input, as code in a
# language of their own: no shell parse is possible, the regex check decides.
CODE_HEADS = frozenset({"osascript", "expect", "perl", "ruby", "node", "deno", "bun", "php", "lua"})
SSH_VALUE_OPTS = "BbcDEeFIiJLlmOoPpQRSWw"


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


class _Ctx:
    """State of one check_command call."""
    __slots__ = ("full", "has_tmux", "seen", "assigned")

    def __init__(self, full):
        self.full = full
        self.has_tmux = re.search("tmux", full, re.I) is not None
        self.seen = set()   # texts already checked and found clean
        self.assigned = {}  # NAME -> value of the NAME=value words seen so far


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


def _match(s, i, opener, closer, squote=True):
    """Index of the closer that matches the opener at s[i], or len(s).
    squote: single quotes quote (false inside double quotes, where an
    apostrophe is a plain character). Here-document bodies are skipped."""
    depth = 0
    n = len(s)
    k = i
    pending = []
    while k < n:
        c = s[k]
        if c == "\\":
            k += 2
            continue
        if c == "\n" and pending:
            k += 1
            for delim, strip in pending:
                while k < n:
                    j = s.find("\n", k)
                    if j < 0:
                        j = n
                    line = s[k:j]
                    k = min(j + 1, n)
                    if (line.lstrip("\t") if strip else line) == delim:
                        break
            pending = []
            continue
        if c == "<" and s.startswith("<<", k) and not s.startswith("<<<", k):
            m = _HEREDOC_OPEN_RE.match(s, k)
            if m:
                pending.append((m.group(2).strip("'\"").replace("\\", ""), m.group(1) == "-"))
                k = m.end()
                continue
        if squote and c == "'":
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
            if _HEREDOC_WORD_RE.match(target.text):  # not the shift in (( 1 << 4 ))
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

    def _dollar(self, i, buf, dq=False):
        """At s[i] == '$'. dq: inside double quotes. Returns (next index,
        still literal)."""
        s, n = self.s, self.n
        nx = s[i + 1] if i + 1 < n else ""
        if nx == "(":
            j = _match(s, i + 1, "(", ")")
            self.subs.append(s[i + 2:j])
            buf.append(s[i:j + 1])
            return j + 1, False
        if nx == "{":
            j = _match(s, i + 1, "{", "}", not dq)
            self._nested(s[i + 2:j], not dq)
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
                i, lit = self._dollar(i, buf, True)
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


def _socket_problem(sock_s, sock_l, ctx):
    """None when the invocation names a server of its own; else what is wrong."""
    if sock_s is not None:
        text, literal = sock_s
        if text == "" and literal:
            return "-S has an empty path"
        if _INHERITED_SOCK_RE.search(text):
            return "-S resolves to the inherited server ($TMUX / socket_path)"
        if _DEFAULT_SOCK_RE.search(text):
            return "-S names the default server's socket"
        if not literal and "/" not in text and _DEFAULT_SOCK_DIR_RE.search(ctx.full):
            return "-S is a variable and the line names the default socket directory (/tmp/tmux-<uid>)"
        for var in _VAR_RE.findall(text) if not literal else ():
            value = ctx.assigned.get(var, "")
            if _INHERITED_SOCK_RE.search(value) or _DEFAULT_SOCK_RE.search(value):
                return "-S is $%s, which this line set from the inherited or the default server" % var
        return None
    if sock_l is not None:
        text, literal = sock_l
        if text == "" and literal:
            return "-L has an empty name"
        if text == "default":
            return "-L default names the default server"
        if _INHERITED_SOCK_RE.search(text):
            return "-L is built from the inherited server ($TMUX / socket_path)"
        return None
    return "no -S/-L on this tmux invocation"


def _check_tmux(args, cmd, ctx, strict=False):
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
    problem = _socket_problem(sock_s, sock_l, ctx)
    if problem is None:
        return None
    at_command = True
    for arg in rest:
        if KILL_RE.search(arg.text):
            return "tmux kill-server: " + problem
        if at_command and not arg.literal and not strict:
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


def _check_shell(args, cmd, depth, ctx, c_only=False):
    """args: the words after a shell's name (sh, bash, ...). c_only: the name
    is an expansion ("$SHELL"), so only a -c string is taken as a script."""
    j = 0
    from_stdin = False
    while j < len(args):
        arg = args[j]
        text = arg.text
        if arg.literal and len(text) > 1 and text[0] in "-+":
            if text[0] == "-" and not text.startswith("--"):
                if "c" in text[1:]:
                    k = j + 1
                    while k < len(args) and args[k].literal and args[k].text.startswith("-"):
                        k += 1
                    if k < len(args):
                        return _check_script(args[k], depth, ctx)
                    return None
                if "s" in text[1:]:
                    from_stdin = True  # bash -s -- arg: the script is stdin whatever follows
            if text in ("-o", "-O", "+o", "+O", "--rcfile", "--init-file"):
                j += 1
            j += 1
            continue
        break
    if c_only:
        return None
    # No script file: the script is stdin. /dev/stdin is stdin too.
    if from_stdin or j >= len(args) or args[j].text in ("-", "/dev/stdin"):
        for text in _stdin_texts(cmd):
            reason = _check_text(text, depth + 1, ctx)
            if reason:
                return reason
    return None


def _check_script(word, depth, ctx):
    """A word that a shell or eval runs as a script."""
    reason = _check_text(word.text, depth + 1, ctx)
    if reason or word.literal:
        return reason
    # The script is a variable: check what the line assigned to it.
    return _check_assigned([word], depth, ctx)


def _check_assigned(words, depth, ctx):
    """words run as a command or a script: check the values this line
    assigned to the variables they name (`cmd="tmux ..."; $cmd`)."""
    for word in words:
        for var in _VAR_RE.findall(word.text):
            value = ctx.assigned.get(var)
            if value and _mentions_kill(value):
                reason = _check_text(value, depth + 1, ctx)
                if reason:
                    return "through $%s, set on this line: %s" % (var, reason)
    return None


def _ssh_remote_command(args):
    """The words of ssh's remote command (empty: a login shell on stdin)."""
    i = 0
    while i < len(args):
        text = args[i].text
        if args[i].literal and text.startswith("-") and len(text) > 1:
            i += 2 if (len(text) == 2 and text[1] in SSH_VALUE_OPTS) else 1
            continue
        return args[i + 1:]  # args[i] is the host
    return []


def _check_cmd(cmd, depth, ctx):
    words = list(cmd.words)
    while words:
        word = words[0]
        if word.assign:
            ctx.assigned[word.text.partition("=")[0].rstrip("+")] = word.text.partition("=")[2]
            words.pop(0)
            continue
        if word.plain and word.text in RESERVED:
            words.pop(0)
            continue
        name = _base(word)
        if name in WRAPPERS:
            words.pop(0)
            value_opts = WRAPPER_VALUE_OPTS.get(name, "")
            while words and words[0].literal and words[0].text.startswith("-"):
                text = words.pop(0).text
                if len(text) == 2 and text[1] in value_opts and words:
                    words.pop(0)  # sudo -u root, nice -n 5, exec -a name
            if name in WRAPPER_OPERAND and words:
                words.pop(0)  # timeout 5, flock /path/lock
            continue
        if name == "env":
            words.pop(0)
            while words:
                word = words[0]
                if word.assign:
                    words.pop(0)
                elif word.literal and word.text.startswith("-"):
                    if word.text in ("-S", "--split-string"):
                        return _check_text(" ".join(w.text for w in words[1:]), depth + 1, ctx)
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
        reason = _check_text(" ".join(w.text for w in args), depth + 1, ctx)
        if reason is None:
            reason = _check_assigned(args, depth, ctx)
        return reason
    if name == "trap":
        for arg in args:
            reason = _check_text(arg.text, depth + 1, ctx)
            if reason:
                return reason
        return None
    if name == "alias":
        for arg in args:
            reason = _check_text(arg.text.partition("=")[2], depth + 1, ctx)
            if reason:
                return reason
        return None

    names = [_base(w) for w in words]
    if "tmux" in names:
        # Also when tmux is not the first word: an unknown command in front of
        # it (xargs, find -exec, a wrapper script) may run it.
        reason = _check_tmux(words[names.index("tmux") + 1:], cmd, ctx)
        if reason:
            return reason
    elif name is None:
        if ctx.has_tmux:
            # `"$TMUX_BIN" kill-server`, `$(command -v tmux) kill-server`.
            reason = _check_tmux(args, cmd, ctx, strict=True)
            if reason:
                return "the command name is a variable and the line mentions tmux; " + reason
        # `"$SHELL" -c '...'`, `"$BASH" -lc "..."`. A variable that names a
        # shell by convention also reads a script from stdin (`"$BASH" <<EOF`).
        reason = _check_shell(args, cmd, depth, ctx, c_only=not _SHELL_VAR_RE.search(words[0].text))
        if reason:
            return reason
        # `cmd="tmux ..."; $cmd`
        reason = _check_assigned(words[:1], depth, ctx)
        if reason:
            return reason
    shell_at = next((n for n, base in enumerate(names) if base in SHELLS), None)
    if shell_at is not None:
        reason = _check_shell(words[shell_at + 1:], cmd, depth, ctx)
        if reason:
            return reason
    if name in ("ssh", "mosh") and shell_at is None:
        remote = _ssh_remote_command(args)
        if not remote:
            # `ssh host <<EOF`: the remote login shell reads the script from stdin.
            for text in _stdin_texts(cmd):
                reason = _check_text(text, depth + 1, ctx)
                if reason:
                    return reason
        elif depth < MAX_DEPTH:
            # `ssh host 'bash -s' <<EOF`: the remote command gets ssh's stdin.
            # 'cat > file' stays text; a shell or an interpreter is checked.
            stdin = _stdin_texts(cmd)
            if any(_mentions_kill(text) for text in stdin):
                remote_cmds, _ = _Lexer(" ".join(w.text for w in remote)).run()
                for remote_cmd in remote_cmds:
                    remote_cmd.stdin = list(remote_cmd.stdin) + stdin
                    reason = _check_cmd(remote_cmd, depth + 1, ctx)
                    if reason:
                        return reason
    if name in SHELL_STRING_HEADS:
        for arg in args:
            if _mentions_kill(arg.text):
                reason = _check_text(arg.text, depth + 1, ctx)
                if reason:
                    return reason
    if name in CODE_HEADS or (name and _PYTHON_RE.match(name)):
        # String arguments, here-documents and here-strings (not the pipeline
        # stage in front: `echo '{json}' | python3 script.py` is data).
        for text in [a.text for a in args] + list(cmd.stdin):
            if _mentions_kill(text) and _loose(text):
                return "code given to `%s` runs tmux kill-server without -S/-L" % name
    return None


def _check_text(text, depth, ctx):
    if text in ctx.seen:
        return None
    if depth > MAX_DEPTH or len(ctx.seen) >= MAX_STEPS:
        return "too nested to parse; tmux kill-server without -S/-L" if _loose(text) else None
    cmds, subs = _Lexer(text).run()
    for sub in subs:
        reason = _check_text(sub, depth + 1, ctx)
        if reason:
            return reason
    in_test = False
    for cmd in cmds:
        # [[ a && b ]] is split at && like a command list: skip up to "]]".
        if not in_test and cmd.words and cmd.words[0].plain and cmd.words[0].text == "[[":
            in_test = True
        if in_test:
            in_test = not any(w.plain and w.text == "]]" for w in cmd.words)
            continue
        reason = _check_cmd(cmd, depth, ctx)
        if reason:
            return reason
    ctx.seen.add(text)
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
        return _check_text(command, 0, _Ctx(command))
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
