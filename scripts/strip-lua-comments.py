#!/usr/bin/env python3
"""Drop comment lines from Lua sources, in place.

    strip-lua-comments.py <file>...

The Lua counterpart of strip-shell-comments.py, for parkeze-rs485: whole-line
`--` comments go and everything else stays, so line numbers in a gateway's
error messages still mean something after a blank line or two less. A `--`
after code may be inside a string, and the long comments worth removing are
the whole-line ones anyway.

A long bracket (`[[`, `[=[`, `--[[`) can hold a line that starts with `--` and
is not a comment, and telling which takes a Lua lexer. None of ours use one,
so a file that does is refused rather than guessed at.
"""

import re
import sys

LONG_BRACKET = re.compile(r"\[=*\[")


def strip(text, path):
    if LONG_BRACKET.search(text):
        raise SystemExit(f"error: {path} has a long bracket; strip-lua-comments.py cannot tell its comments apart")
    out = []
    for n, line in enumerate(text.split("\n")):
        if n == 0 and line.startswith("#!"):
            out.append(line)
            continue
        if line.lstrip().startswith("--"):
            continue
        out.append(line)
    return "\n".join(out)


def main(paths):
    for path in paths:
        with open(path, encoding="utf-8", errors="surrogateescape") as f:
            text = f.read()
        stripped = strip(text, path)
        if stripped != text:
            with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
                f.write(stripped)


if __name__ == "__main__":
    main(sys.argv[1:])
