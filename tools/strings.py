#!/usr/bin/env python3
"""Baut Resources/Localizable.xcstrings aus den Texten, die der Compiler beim Bauen extrahiert (*.stringsdata),
plus englischen Übersetzungen aus tools/en.json. Deutsch ist die Entwicklungssprache (Schlüssel = deutscher Text).
Aufruf nach einem Build:  python3 tools/strings.py   (meldet fehlende Übersetzungen)"""
import glob, json, os, sys
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
keys = set()
for f in glob.glob(os.path.join(root, "build/Build/Intermediates.noindex/HomeRollTV.build/*/HomeRollTV*.build/**/*.stringsdata"), recursive=True):
    if "UITests" in f: continue
    d = json.load(open(f))
    for e in d.get("tables", {}).get("Localizable", []):
        keys.add(e["key"])
# Laufzeit-Texte (L(…)) – Suchideen
keys |= {"Die Mediathek auf dem Server ist leer.", "Strand", "Sonnenuntergang", "Berge", "Essen", "Hund", "Katze", "Schnee", "Stadt", "Auto", "Blumen"}
en = json.load(open(os.path.join(root, "tools/en.json")))
missing = sorted(k for k in keys if k not in en and k.strip() and not k.replace("%lld", "").replace("%@", "").strip(" ·:") == "")
strings = {}
for k in sorted(keys):
    entry = {}
    if k in en:
        entry = {"localizations": {"en": {"stringUnit": {"state": "translated", "value": en[k]}}}}
    strings[k] = entry
out = {"sourceLanguage": "de", "strings": strings, "version": "1.0"}
with open(os.path.join(root, "Resources/Localizable.xcstrings"), "w") as fh:
    json.dump(out, fh, ensure_ascii=False, indent=2, sort_keys=True)
print(f"{len(keys)} Texte, {len(missing)} ohne Übersetzung")
for k in missing: print("  ", json.dumps(k, ensure_ascii=False))
unused = sorted(set(en) - keys)
if unused: print("nicht mehr benutzt:", unused)
