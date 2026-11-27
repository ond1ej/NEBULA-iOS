#!/usr/bin/env python3
"""Check Localization/Localizable.xcstrings against what the compiler actually extracts.

Build once with string extraction on (the generated project already sets SWIFT_EMIT_LOC_STRINGS=YES), pointing
DerivedData at a folder you choose, then run this on it (from the repository root):

    xcodebuild -project NEBULA.xcodeproj -scheme "NEBULA iOS" -destination 'generic/platform=iOS Simulator' \\
        -derivedDataPath build/dd-loc CODE_SIGNING_ALLOWED=NO build
    python3 scripts/check_localizations.py build/dd-loc [--lang cs]

Exit code 1 if a key used in the code is missing from the catalog or has no translation in --lang.
Keys that are the same word in every language (brand names, key caps) are listed as "identical" and are fine.
"""
from __future__ import annotations

import argparse
import glob
import json
import re
import sys
from pathlib import Path

CATALOG = Path(__file__).resolve().parents[1] / "Localization/Localizable.xcstrings"  # relative to the repository root


def used_keys(derived: str) -> set[str]:
    keys: set[str] = set()
    for f in glob.glob(f"{derived}/**/*.stringsdata", recursive=True):
        for item in json.load(open(f)).get("tables", {}).get("Localizable", []):
            keys.add(item["key"])
    return {k for k in keys if re.search("[A-Za-z]", re.sub(r"%(?:\d+\$)?(?:lld|ld|lf|@|d|f|s)", "", k))}


def has_translation(entry: dict, lang: str) -> bool:
    loc = entry.get("localizations", {}).get(lang)
    if not loc:
        return False
    if "stringUnit" in loc:
        return loc["stringUnit"].get("state") == "translated"
    return bool(loc.get("variations"))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("derived_data")
    ap.add_argument("--lang", default="cs")
    args = ap.parse_args()
    catalog = json.load(open(CATALOG))["strings"]
    used = used_keys(args.derived_data)
    if not used:
        print("no .stringsdata found: build first with SWIFT_EMIT_LOC_STRINGS=YES", file=sys.stderr)
        return 2
    missing = sorted(used - catalog.keys())
    untranslated = sorted(k for k in used & catalog.keys() if not has_translation(catalog[k], args.lang))
    identical = sorted(k for k in used & catalog.keys()
                       if has_translation(catalog[k], args.lang)
                       and catalog[k].get("localizations", {}).get(args.lang, {}).get("stringUnit", {}).get("value") == k)
    unused = sorted(catalog.keys() - used)
    print(f"{len(used)} keys in the code, {len(catalog)} in the catalog")
    for title, items in (("missing from the catalog", missing), (f"without a {args.lang} translation", untranslated)):
        print(f"{title}: {len(items)}")
        for k in items:
            print("   ", repr(k))
    print(f"identical in {args.lang}: {len(identical)}; in the catalog but not in this build: {len(unused)}"
          " (macOS-only or iOS-only strings show up as unused when you check one platform)")
    return 1 if missing or untranslated else 0


if __name__ == "__main__":
    raise SystemExit(main())
