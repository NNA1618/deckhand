#!/usr/bin/env python3
"""Prints update.json for a release: what Deckhand's updater reads from the latest release.

Usage: update-manifest.py VERSION BUILD MINIMUM_SYSTEM SIGNATURE URL
Short notes for the About pane come from release-notes/vVERSION.update.json when it exists:
{"en": "...", "ru": "..."}, plain text.
"""
import json
import os
import sys

version, build, minimum, signature, url = sys.argv[1:6]
manifest = {"version": version, "build": int(build), "url": url, "signature": signature, "minimumSystem": minimum}
notes = os.path.join(os.path.dirname(__file__), "..", "release-notes", f"v{version}.update.json")
if os.path.exists(notes):
    with open(notes, encoding="utf-8") as f:
        manifest["notes"] = json.load(f)
print(json.dumps(manifest, ensure_ascii=False, indent=2))
