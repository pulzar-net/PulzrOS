#!/usr/bin/env python3
"""Find calls to ucode functions that are defined further down the file.

ucode does not hoist function declarations. A `function f()` defined below a
function that calls it is not in scope there, and the call fails at RUNTIME
with "left-hand side is not a function" — never at compile time. Every ucode
file we ship compiled cleanly while carrying twelve of these, and the first one
only surfaced when somebody tried to sign in.

The fix in lib/*.uc is to declare every name up front and assign the bodies, so
definition order stops mattering. This catches anything that slips back to the
declaration form and still reads forward.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def forward_refs(path):
    lines = path.read_text().split("\n")

    # Top-level definitions, in either form, with the line they become usable.
    defs = {}
    for i, line in enumerate(lines):
        m = re.match(r"^(?:function (\w+)\s*\(|(\w+)\s*=\s*function\s*\()", line)
        if m:
            defs[m.group(1) or m.group(2)] = i

    # Names declared up front are usable everywhere, so they are never forward
    # references no matter where the body sits.
    predeclared = set()
    for line in lines:
        m = re.match(r"^let ([\w,\s]+);\s*$", line)
        if m:
            predeclared.update(n.strip() for n in m.group(1).split(","))

    problems, current, current_line, depth = [], None, None, 0
    for i, line in enumerate(lines):
        m = re.match(r"^(?:function (\w+)\s*\(|(\w+)\s*=\s*function\s*\()", line)
        if m:
            current = m.group(1) or m.group(2)
            current_line, depth = i, 0
        if current is None:
            continue
        depth += line.count("{") - line.count("}")
        if not line.startswith("function ") and "= function" not in line:
            for name, dline in defs.items():
                if name == current or name in predeclared:
                    continue
                if dline > current_line and re.search(r"\b%s\s*\(" % re.escape(name), line):
                    problems.append((current, current_line + 1, name, dline + 1, i + 1))
        if depth <= 0 and i > current_line:
            current = None
    return problems


def main():
    failures = 0
    for path in sorted(ROOT.glob("feed/**/*.uc")):
        seen = set()
        for caller, cline, callee, dline, useline in forward_refs(path):
            if (caller, callee) in seen:
                continue
            seen.add((caller, callee))
            if not failures:
                print("ucode does not hoist function declarations:\n")
            rel = path.relative_to(ROOT)
            print(f"  {rel}:{useline}")
            print(f"    {caller}() (line {cline}) calls {callee}(), defined at line {dline}")
            print("    This compiles and throws at runtime. Declare the names up")
            print("    front (`let a, b, c;`) and assign the bodies.\n")
            failures += 1
    if failures:
        print(f"{failures} forward reference(s)")
        return 1
    print("No ucode forward references.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
