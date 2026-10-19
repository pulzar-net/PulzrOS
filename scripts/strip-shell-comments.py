#!/usr/bin/env python3
"""Drop comment lines from shell scripts, in place.

    strip-shell-comments.py <file>...

Only whole-line comments go. A `#` after code may be inside a string, and
telling which takes a shell parser; the long comments worth removing are the
whole-line ones anyway. Kept: the shebang, any line starting `#!` (a script a
script writes), and every line of a here-document, which is data that might be
a config file or a script of its own.
"""

import re
import sys

HEREDOC = re.compile(r"<<(-?)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")


def strip(text):
    out = []
    pending = []          # here-document terminators opened on this line
    body = None           # (terminator, allow_tabs) while inside one
    for n, line in enumerate(text.split("\n")):
        if body is not None:
            out.append(line)
            word, tabs = body
            if (line.lstrip("\t") if tabs else line) == word:
                body = pending.pop(0) if pending else None
            continue
        bare = line.lstrip()
        if n == 0 and line.startswith("#!"):
            out.append(line)
            continue
        if bare.startswith("#") and not bare.startswith("#!"):
            continue
        out.append(line)
        # A comment after code can mention `<<`; only the code part counts.
        for m in HEREDOC.finditer(line):
            pending.append((m.group(3), m.group(1) == "-"))
        if pending:
            body = pending.pop(0)
    return "\n".join(out)


def main(paths):
    for path in paths:
        with open(path, encoding="utf-8", errors="surrogateescape") as f:
            text = f.read()
        stripped = strip(text)
        if stripped != text:
            with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
                f.write(stripped)


if __name__ == "__main__":
    main(sys.argv[1:])
