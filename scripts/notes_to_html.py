#!/usr/bin/env python3
"""Render a CHANGELOG section (markdown) to simple HTML for the Sparkle update dialog."""
import html
import re
import sys


def inline(s: str) -> str:
    s = html.escape(s)
    s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
    s = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", s)
    return s


def main() -> None:
    lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
    out = ['<html><body style="font:13px -apple-system,system-ui,sans-serif;color:#222">']
    in_list = False
    for ln in lines:
        stripped = ln.strip()
        if ln.startswith("### "):
            if in_list:
                out.append("</ul>")
                in_list = False
            out.append(f'<h3 style="margin:10px 0 4px">{inline(ln[4:])}</h3>')
        elif stripped.startswith("- "):
            if not in_list:
                out.append('<ul style="margin:4px 0 8px 18px;padding:0">')
                in_list = True
            out.append(f"<li>{inline(stripped[2:])}</li>")
        elif stripped and in_list and ln.startswith(" ") and out[-1].endswith("</li>"):
            # A wrapped continuation of the previous bullet: fold it back into that list item.
            out[-1] = out[-1][: -len("</li>")] + " " + inline(stripped) + "</li>"
        elif stripped:
            if in_list:
                out.append("</ul>")
                in_list = False
            out.append(f'<p style="margin:4px 0">{inline(stripped)}</p>')
    if in_list:
        out.append("</ul>")
    out.append("</body></html>")
    print("\n".join(out))


if __name__ == "__main__":
    main()
