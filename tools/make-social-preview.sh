#!/bin/bash
# Draws the card GitHub shows when the repository is linked somewhere — Settings → Social
# preview, which has to be uploaded by hand. 1280x640, and shown small and often cropped,
# so it is built as a shape rather than as a page.
#
# JPEG because GitHub caps the upload at 1 MB and this card is mostly a screenshot.
#
# Kept as code beside the picture it makes, for the same reason the app icon is: a PNG
# nobody can regenerate is a PNG nobody will change.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
swiftc -O -o "$WORK/make" tools/make-social-preview.swift
"$WORK/make" docs/images/social-preview.jpg
