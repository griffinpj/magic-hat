#!/usr/bin/env python3
"""Generate the set symbols the Keyrune font doesn't draw.

Usage: python3 scripts/make-set-icons.py

Scryfall has ~1,050 sets but only ~365 distinct icons: promos, tokens,
art series, the List and the like reuse another set's symbol, named by
the file in `icon_svg_uri` (`abro` -> `bro.svg`, `plst` ->
`planeswalker.svg`). This script writes two things:

- `magic-hat/Resources/set-icons.json`: `{"aliases": {code: icon},
  "bundled": [icon, ...]}` for every set whose own code Keyrune lacks
  (after its `p…`/`t…` fallback). Most of those icons *are* Keyrune
  glyphs under the parent's code; the rest are bundled.
- `magic-hat/Assets.xcassets/SetIcons/seticon-<icon>.imageset`: the SVG of
  every icon Keyrune has no glyph for, as a template image with its vector
  data preserved. Xcode compiles them into the asset catalog at build
  time, so the app draws them like any image — no network, no WebKit.

Run it when a set releases (Keyrune's map is regenerated the same way).
Sets newer than the last run still fall back to the WebKit rasterizer.
A network fetch in every build would tie builds to Scryfall and break
offline and script-sandboxed builds, so the output is committed.
"""
import json, pathlib, shutil, time, urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
KEYRUNE = ROOT / "magic-hat/Resources/keyrune-map.json"
OUT_JSON = ROOT / "magic-hat/Resources/set-icons.json"
CATALOG = ROOT / "magic-hat/Assets.xcassets/SetIcons"
HEADERS = {"User-Agent": "MagicHat/1.0", "Accept": "application/json"}


def get(url, accept=None):
    headers = dict(HEADERS)
    if accept:
        headers["Accept"] = accept
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers)) as response:
        return response.read()


keyrune = json.loads(KEYRUNE.read_text())


def keyrune_has(code):
    """Mirrors KeyruneFont.glyph(for:): the code, else a promo/token
    code's parent."""
    code = code.lower()
    return code in keyrune or (len(code) > 3 and code[0] in "pt" and code[1:] in keyrune)


sets = json.loads(get("https://api.scryfall.com/sets"))["data"]
aliases, bundled = {}, {}
for s in sets:
    code = s["code"].lower()
    if keyrune_has(code):
        continue
    uri = s["icon_svg_uri"]
    icon = uri.rsplit("/", 1)[-1].split("?")[0].rsplit(".", 1)[0].lower()
    aliases[code] = icon
    if not keyrune_has(icon):
        bundled[icon] = uri

# The asset folder is rebuilt from scratch so icons no longer needed go.
if CATALOG.exists():
    shutil.rmtree(CATALOG)
CATALOG.mkdir(parents=True)
(CATALOG / "Contents.json").write_text(json.dumps(
    {"info": {"author": "xcode", "version": 1}, "properties": {"provides-namespace": False}}, indent=2) + "\n")

for icon, uri in sorted(bundled.items()):
    svg = get(uri, accept="image/svg+xml")
    folder = CATALOG / f"seticon-{icon}.imageset"
    folder.mkdir()
    (folder / f"{icon}.svg").write_bytes(svg)
    (folder / "Contents.json").write_text(json.dumps({
        "images": [{"filename": f"{icon}.svg", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {"preserves-vector-representation": True, "template-rendering-intent": "template"},
    }, indent=2) + "\n")
    time.sleep(0.1)   # Scryfall asks for 50–100ms between requests

OUT_JSON.write_text(json.dumps(
    {"aliases": dict(sorted(aliases.items())), "bundled": sorted(bundled)}, indent=1, sort_keys=True) + "\n")
print(f"{len(aliases)} sets aliased, {len(bundled)} icons bundled")
