#!/usr/bin/env python3
"""Generate Resources/mana-map.json from the Mana font's CSS.

Usage: python3 scripts/make-mana-map.py [path/to/mana.css]

Without a path, fetches css/mana.css from the Mana repository. The map is
`{ "<class without ms->": "<hex code point>" }`, e.g. `"w": "e600"`, and
covers every *single* glyph in the font (mana, tap/untap, card types,
keyword abilities, counters, watermarks).

Hybrid symbols (`ms-wu`, `ms-2w`, `ms-wp`, …) are not glyphs: Mana composes
them in CSS from two half-size single glyphs over a split background. They
are deliberately left out; `ManaSymbolView` composes them the same way from
the symbol's parts.
"""
import json, re, sys, urllib.request, pathlib

URL = "https://raw.githubusercontent.com/andrewgioia/mana/master/css/mana.css"

if len(sys.argv) > 1:
    css = pathlib.Path(sys.argv[1]).read_text()
else:
    css = urllib.request.urlopen(URL).read().decode("utf-8")

rule = re.compile(r'([^{}]+)\{\s*content:\s*"\\([0-9a-f]+)"\s*;?\s*\}', re.S)
before, after = {}, set()
for selectors, code in rule.findall(css):
    for sel in selectors.split(","):
        sel = sel.strip()
        m = re.fullmatch(r'\.ms-([a-z0-9-]+)::(before|after)', sel)
        if not m:
            continue  # .ms-cost.ms-x variants and anything compound
        name, pseudo = m.groups()
        if pseudo == "after":
            after.add(name)
        else:
            before.setdefault(name, code)

mapping = {n: c for n, c in before.items() if n not in after}

out = pathlib.Path(__file__).resolve().parent.parent / "magic-hat" / "Resources" / "mana-map.json"
out.write_text(json.dumps(mapping, indent=0, sort_keys=True) + "\n")
print(f"{len(mapping)} single glyphs ({len(after)} composed symbols skipped) -> {out}")
