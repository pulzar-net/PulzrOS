#!/usr/bin/env python3
"""Refuse emoji in anything a person sees.

A gateway console is an instrument panel. Emoji in it read as decoration on a
device whose job is to tell you plainly whether something is broken, and they
render inconsistently across the browsers and terminals this ends up in — a
serial console at 115200 is not going to draw a colour glyph.

Status is carried by badges, icons and colour, all of which are already here.

Covers the console source, the packaged shell and ucode, and the docs. Ignores
build output, which is generated.
"""
import pathlib
import re
import sys
import unicodedata

ROOT = pathlib.Path(__file__).resolve().parent.parent

INCLUDE = [
    "console/src/**/*.ts", "console/src/**/*.tsx", "console/src/**/*.css",
    "console/index.html",
    "feed/**/*.uc", "feed/**/*.sh", "docs/**/*.md", "README.md",
    "boards/**/*.conf",
]
SKIP_PARTS = {"node_modules", "dist", "www", ".git", ".build", "out"}

# Pictographic ranges. Deliberately NOT the arrows, box drawing, or typographic
# punctuation this codebase uses on purpose (→ · — ─ ══).
EMOJI = re.compile(
    "[" 
    "\U0001F000-\U0001FAFF"   # pictographs, symbols, supplemental
    "\U00002600-\U000026FF"   # misc symbols
    "\U00002700-\U000027BF"   # dingbats
    "\U0001F1E6-\U0001F1FF"   # regional indicators (flags)
    "\U0000FE0F"              # variation selector 16 (emoji presentation)
    "]"
)


def main() -> int:
    hits = []
    seen = set()
    for pattern in INCLUDE:
        for path in ROOT.glob(pattern):
            if path in seen or not path.is_file():
                continue
            if SKIP_PARTS & set(path.parts):
                continue
            seen.add(path)
            try:
                text = path.read_text(encoding="utf-8")
            except (UnicodeDecodeError, OSError):
                continue
            for n, line in enumerate(text.split("\n"), 1):
                for m in EMOJI.finditer(line):
                    ch = m.group()
                    name = unicodedata.name(ch, "unnamed")
                    hits.append((path.relative_to(ROOT), n, ch, name))

    if hits:
        print("Emoji are not used in this project:\n")
        for rel, n, ch, name in hits:
            print(f"  {rel}:{n}  {ch!r}  ({name})")
        print(f"\n{len(hits)} occurrence(s). Use a Badge, an icon, or colour.")
        return 1

    print(f"No emoji in {len(seen)} files.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
