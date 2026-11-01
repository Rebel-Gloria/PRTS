"""Formatting-independent source guards; these supplement, never replace, Swift tests."""

import re
import textwrap

TOKEN = re.compile(r'"""[\s\S]*?"""|"(?:\\[\s\S]|[^"\\])*"|//[^\n]*|/\*[\s\S]*?\*/|\w+|[^\s]')


def swift_code(source):
    """Keep literals and code while ignoring comments, layout and optional separators."""
    tokens = []
    for match in TOKEN.finditer(source):
        token = match.group()
        if token.startswith(("//", "/*")) or token == ";":
            continue
        if token.startswith('"""'):
            token = '"""' + textwrap.dedent(token[3:-3]).strip("\n") + '"""'
        if token in (")", "]", "}") and tokens and tokens[-1] == ",":
            tokens.pop()
        tokens.append(token)
    return "".join(tokens)


def source_file(root, name):
    matches = list(root.rglob(name))
    if len(matches) != 1:
        raise AssertionError(f"Expected one {name} below {root}, found {len(matches)}")
    return matches[0]
