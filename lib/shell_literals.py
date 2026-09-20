"""Nonexecuting parser for a deliberately restricted shell literal vocabulary.

This is not a shell parser: operators, expansions, substitutions, double quotes,
and control characters outside quotes are rejected, not interpreted. Callers
must separately validate any command structure surrounding these literal words.
"""


class ShellLiteralError(ValueError):
    """Input is outside the supported, unambiguous literal grammar."""


# Unquoted characters with no expansion, operator, glob, or shell comment role.
_SAFE_ASCII = frozenset('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:@%+=,-')
_ANSI_ESCAPES = {'a': 7, 'b': 8, 'e': 27, 'f': 12, 'n': 10, 'r': 13,
                 't': 9, 'v': 11, '\\': 92, "'": 39, '"': 34}


def parse_words(text, allow_ansi=False):
    """Return literal arguments or raise ShellLiteralError; never evaluate input.

    Whitespace is ASCII space/tab only. Quotes and escaped characters concatenate
    within a word. ANSI-C quotes are opt-in; their octal escapes encode bytes,
    which must collectively decode as valid UTF-8. NUL is always forbidden.
    """
    if not isinstance(text, str):
        raise ShellLiteralError('Expected text')
    try:
        text.encode('utf-8', errors='strict')
    except UnicodeError as exc:
        raise ShellLiteralError('Input is not valid UTF-8 text') from exc
    if '\x00' in text:
        raise ShellLiteralError('NUL is forbidden')
    words, word = [], []
    active = False
    index = 0
    while index < len(text):
        char = text[index]
        if char in ' \t':
            if active:
                words.append(''.join(word))
                word, active = [], False
            index += 1
            continue
        active = True
        if char == "'":
            end = text.find("'", index + 1)
            if end < 0:
                raise ShellLiteralError('Unterminated single quote')
            word.append(text[index + 1:end])
            index = end + 1
        elif char == '\\':
            index += 1
            if index == len(text):
                raise ShellLiteralError('Trailing backslash')
            if ord(text[index]) < 32 or ord(text[index]) == 127:
                raise ShellLiteralError('Escaped control character is forbidden')
            word.append(text[index])
            index += 1
        elif char == '$' and allow_ansi and text[index:index + 2] == "$'":
            index += 2
            value = bytearray()
            while True:
                if index >= len(text):
                    raise ShellLiteralError('Unterminated ANSI-C quote')
                char = text[index]
                index += 1
                if char == "'":
                    break
                if char != '\\':
                    value.extend(char.encode('utf-8'))
                    continue
                if index >= len(text):
                    raise ShellLiteralError('Trailing ANSI-C escape')
                char = text[index]
                index += 1
                if char in _ANSI_ESCAPES:
                    value.append(_ANSI_ESCAPES[char])
                elif char in '01234567':
                    digits = char
                    while len(digits) < 3 and index < len(text) and text[index] in '01234567':
                        digits += text[index]
                        index += 1
                    byte = int(digits, 8)
                    if byte > 255:
                        raise ShellLiteralError('Octal escape exceeds one byte')
                    value.append(byte)
                else:
                    raise ShellLiteralError('Unsupported ANSI-C escape')
            if 0 in value:
                raise ShellLiteralError('NUL is forbidden')
            try:
                word.append(value.decode('utf-8', errors='strict'))
            except UnicodeError as exc:
                raise ShellLiteralError('ANSI-C bytes are not valid UTF-8') from exc
        elif char in _SAFE_ASCII or (ord(char) > 127 and not char.isspace() and char.isprintable()):
            word.append(char)
            index += 1
        else:
            raise ShellLiteralError('Unsupported unquoted shell syntax')
    if active:
        words.append(''.join(word))
    return words
