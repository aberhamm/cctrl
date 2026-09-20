#!/usr/bin/env python3
"""Literal grammar fixtures only. No shell is ever invoked."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('shell_literals', Path(__file__).resolve().parents[1] / 'lib/shell_literals.py')
parser = importlib.util.module_from_spec(spec)
spec.loader.exec_module(parser)


class ShellLiteralTests(unittest.TestCase):
    def test_basic_words_whitespace_and_empty_arguments(self):
        self.assertEqual(parser.parse_words(" \t codex --model=gpt-6-astra '' /tmp/repo "),
                         ['codex', '--model=gpt-6-astra', '', '/tmp/repo'])
        self.assertEqual(parser.parse_words(' \t '), [])

    def test_quoted_punctuation_unicode_and_literal_substitution_text(self):
        prompt = 'Hello — café ☃ ; $(touch /tmp/no) `whoami` & | > * ? # ~ !'
        self.assertEqual(parser.parse_words("codex '" + prompt + "'"), ['codex', prompt])
        self.assertEqual(parser.parse_words('codex café'), ['codex', 'café'])

    def test_posix_apostrophe_and_concatenated_segments(self):
        self.assertEqual(parser.parse_words("'can'\\''t' prefix' middle 'suffix"),
                         ["can't", 'prefix middle suffix'])
        self.assertEqual(parser.parse_words(r'a\ b \$literal \; \" \\'),
                         ['a b', '$literal', ';', '"', '\\'])

    def test_ansi_octal_utf8_and_simple_escapes(self):
        self.assertEqual(parser.parse_words(r"$'hello \342\200\224 world'", allow_ansi=True),
                         ['hello — world'])
        self.assertEqual(parser.parse_words(r"$'\n\r\t\b\f\v\a\e\\\'\"'", allow_ansi=True),
                         ['\n\r\t\b\f\v\a\x1b\\\'"'])
        self.assertEqual(parser.parse_words(r"$'\101\12\7'", allow_ansi=True), ['A\n\a'])
        self.assertEqual(parser.parse_words("pre$'café'post", allow_ansi=True), ['precafépost'])

    def test_literal_backslash_octals_are_not_decoded(self):
        self.assertEqual(parser.parse_words(r"'\342\200\224'"), [r'\342\200\224'])
        self.assertEqual(parser.parse_words(r"$'\\342\\200\\224'", allow_ansi=True),
                         [r'\342\200\224'])

    def test_quoted_newline_remains_literal(self):
        self.assertEqual(parser.parse_words("'line\nnext'"), ['line\nnext'])

    def test_ansi_is_opt_in(self):
        with self.assertRaises(parser.ShellLiteralError):
            parser.parse_words("$'text'")

    def test_rejects_operators_expansion_globs_and_controls(self):
        values = ['a;b', 'a && b', 'a|b', 'a > out', 'a < in', '$HOME', '$(whoami)',
                  '`whoami`', '"quoted"', 'a\nb', 'a\rb', '#comment', '~/', '*', '?', '[ab]',
                  '{a,b}', '(a)', '!a', 'a\\\nb', 'a\x7fb', 'a\x1bb', 'a\u00a0b']
        for value in values:
            with self.subTest(value=value):
                with self.assertRaises(parser.ShellLiteralError):
                    parser.parse_words(value, allow_ansi=True)

    def test_rejects_malformed_quotes_and_escapes(self):
        for value in ["'unterminated", 'trailing\\', "$'unterminated", "$'trailing\\",
                      r"$'\x41'", r"$'\u0041'", r"$'\q'", r"$'\777'"]:
            with self.subTest(value=value):
                with self.assertRaises(parser.ShellLiteralError):
                    parser.parse_words(value, allow_ansi=True)

    def test_rejects_nul_invalid_utf8_and_surrogates(self):
        for value in ['a\x00b', "'a\x00b'", r"$'\0'", r"$'\000'", r"$'\377'",
                      r"$'\342\200'", r"$'\300\200'", '\ud800']:
            with self.subTest(value=repr(value)):
                with self.assertRaises(parser.ShellLiteralError):
                    parser.parse_words(value, allow_ansi=True)


if __name__ == '__main__':
    unittest.main()
