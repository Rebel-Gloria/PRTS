"""Formatting-independent source guards; these supplement, never replace, Swift tests."""

import re
import textwrap

TOKEN = re.compile(r'"""[\s\S]*?"""|"(?:\\[\s\S]|[^"\\])*"|//[^\n]*|/\*[\s\S]*?\*/|\w+|[^\s]')


def swift_identifiers(source):
    """Exclude literal/comment tokens before inspecting source dependencies."""
    return {
        match.group() for match in TOKEN.finditer(source) if re.fullmatch(r"\w+", match.group())
    }


def swift_types(source):
    """Find top-level types and aliases regardless of attributes, modifiers and line layout."""
    tokens = [
        match.group()
        for match in TOKEN.finditer(source)
        if not match.group().startswith(('"', "//", "/*"))
    ]
    declarations = {"class", "struct", "enum", "protocol", "actor", "typealias"}
    members = {"func", "var", "let", "subscript"}
    names = set()
    depth = 0
    for index, token in enumerate(tokens[:-1]):
        if token == "{":
            depth += 1
        elif token == "}":
            depth -= 1
        elif depth == 0 and token in declarations:
            name = tokens[index + 1]
            if name not in members and re.fullmatch(r"\w+", name):
                names.add(name)
    return names


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
