#!/usr/bin/env python3
"""Builds offline test fixtures from Scryfall bulk data.

Streams the (large) bulk files once and keeps only what the checked-in
ManaBox export references, so tests exercise the real JSON shape and the real
gzip/JSONL ingest path without touching the network.

    python3 scripts/make-fixtures.py

Writes into magic-hatTests/Fixtures/:
  bulk-data.json                 the /bulk-data manifest as served
  default_cards.slice.jsonl.gz   every printing in ManaBox_Collection.csv
  rulings.slice.jsonl.gz         every ruling for those cards' oracle ids
"""
import csv, gzip, io, json, pathlib, sys, urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIX = ROOT / "magic-hatTests" / "Fixtures"
UA = {"User-Agent": "MagicHat/1.0 (fixture-builder)", "Accept": "application/json"}

def get(url):
    return urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=600)

ids = {r["Scryfall ID"] for r in csv.DictReader(open(FIX / "ManaBox_Collection.csv", newline="", encoding="utf-8")) if r["Scryfall ID"]}
print(f"collection references {len(ids)} printings")

manifest = json.load(get("https://api.scryfall.com/bulk-data"))
(FIX / "bulk-data.json").write_text(json.dumps(manifest, indent=1))
by_type = {e["type"]: e for e in manifest["data"]}

def slice_bulk(kind, keep, out_name):
    uri = by_type[kind]["jsonl_download_uri"]
    print(f"streaming {kind} ({by_type[kind]['compressed_size']/1e6:.1f} MB) ...", flush=True)
    kept = 0
    seen = []
    with get(uri) as resp, gzip.GzipFile(fileobj=resp) as gz, gzip.open(FIX / out_name, "wb", compresslevel=9) as out:
        for line in gz:
            obj = json.loads(line)
            if keep(obj):
                out.write(line if line.endswith(b"\n") else line + b"\n")
                kept += 1
                seen.append(obj)
    size = (FIX / out_name).stat().st_size
    print(f"  kept {kept} -> {out_name} ({size/1e6:.2f} MB)")
    return seen

cards = slice_bulk("default_cards", lambda c: c.get("id") in ids, "default_cards.slice.jsonl.gz")
oracle_ids = {c["oracle_id"] for c in cards if c.get("oracle_id")}
missing = ids - {c["id"] for c in cards}
print(f"  printings not in default_cards (non-English etc.): {len(missing)}")
slice_bulk("rulings", lambda r: r.get("oracle_id") in oracle_ids, "rulings.slice.jsonl.gz")
