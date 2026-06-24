#!/usr/bin/env python3
"""
Convert WeKan's imports/i18n/languages.js into freepascal/public/languages.json.

languages.json has the SAME body as the JS module (the object literal with its `code` / `tag` /
`name` / `load` / `rtl` fields, in source order) — it is just the JS file with the
`export default ` prefix and the trailing `;` removed. This regenerates it from the current
languages.js (e.g. picking up newly added languages).

Usage:
    python3 freepascal/convert-languages.py [languages.js] [languages.json]

Defaults (resolved relative to this script's location):
    src  = ../imports/i18n/languages.js
    dst  = public/languages.json
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_SRC = os.path.normpath(os.path.join(HERE, "..", "imports", "i18n", "languages.js"))
DEFAULT_DST = os.path.join(HERE, "public", "languages.json")


def convert(text: str) -> str:
    # drop a leading BOM and the `export default ` (only the first one, at the top)
    text = re.sub(r"^﻿?\s*export\s+default\s+", "", text, count=1)
    # drop the trailing `;` after the closing brace
    text = text.rstrip()
    if text.endswith(";"):
        text = text[:-1]
    return text + "\n"


def main() -> int:
    src = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SRC
    dst = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_DST
    if not os.path.isfile(src):
        print(f"convert-languages: no such file: {src}", file=sys.stderr)
        return 1
    with open(src, encoding="utf-8") as f:
        out = convert(f.read())
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, "w", encoding="utf-8") as f:
        f.write(out)
    print(f"convert-languages: wrote {dst} ({out.count(chr(10))} lines) from {src}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
