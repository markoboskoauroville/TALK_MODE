#!/bin/bash
# GUARD "one title only" (Marko 15.11.2026). Fails when a window is created without the system title hidden while the app
# draws its own title (TopRow). Run by .github/workflows/mac.yml before the build. MANTRA_MANIFEST modules/one-title-only.md.
cd "$(dirname "$0")/app" || exit 1
fail=0
creators=$(grep -l "NSWindow(\|NSPanel(" *.swift)
for f in $creators; do
  grep -q "titleVisibility = .hidden" "$f" || { echo "FAIL $f creates a window but never sets titleVisibility = .hidden"; fail=1; }
done
grep -q "func enforceOneTitle" *.swift || { echo "FAIL enforceOneTitle() is missing"; fail=1; }
for h in windowDidBecomeKey windowDidResize windowDidEnterFullScreen windowDidExitFullScreen; do
  grep -q "func $h" *.swift || { echo "FAIL $h does not call enforceOneTitle"; fail=1; }
done
grep -q "TopRow.float" *.swift && grep -A1 "static func float" App.swift | grep -q enforceOneTitle || { echo "FAIL the TOP toggle does not re-enforce the title"; fail=1; }
grep -q "titleVisibility = .visible" *.swift && { echo "FAIL titleVisibility = .visible found"; fail=1; }
[ $fail = 0 ] && echo "one title only: OK"
exit $fail
