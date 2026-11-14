#!/usr/bin/env python3
"""Point the generated SPA index at /app/ so it does not collide with /app.js."""

import pathlib
import re
import sys


def main() -> None:
    if len(sys.argv) != 2:
        sys.stderr.write("usage: prefix_spa_assets.py DIST/index.html\n")
        sys.exit(1)
    html_path = pathlib.Path(sys.argv[1])
    dist = html_path.parent

    def replace(match: re.Match[str]) -> str:
        attr, url = match.group(1), match.group(2)
        if not url.startswith("/") or url.startswith("//") or url.startswith("/app/"):
            return match.group(0)
        candidate = dist / url.lstrip("/")
        if candidate.is_file():
            return f'{attr}="/app/{url.lstrip("/")}"'
        return match.group(0)

    updated = re.sub(r'\b(src|href)="([^"]+)"', replace, html_path.read_text(encoding="utf-8"))
    if 'src="/app/fizz_spa.js"' not in updated or 'href="/app/spa.css"' not in updated:
        sys.stderr.write("SPA index.html is missing its /app asset paths.\n")
        sys.exit(1)
    html_path.write_text(updated, encoding="utf-8")


if __name__ == "__main__":
    main()
