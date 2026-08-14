#!/usr/bin/env bash
# Where every PostRoll build puts its DerivedData. Defined once, here, because
# the Makefile and build-install.sh both need it and two spellings of one
# location is how a second cache quietly starts filling (#485, L41).
#
# NOT inside the checkout. The repo lives under ~/Documents, which is synced by
# iCloud, so a cache in there is uploaded, counted against Dan's storage, and
# conflict-copied: iCloud had already minted numbered copies of it that no clean
# step could name. ~/Library is never synced.
#
# Xcode keys DerivedData by the workspace path, so every path that is ever built
# mints its own full copy and nothing reclaims it. That is why this is one fixed
# location rather than a per-run temporary one, and why `make clean` knows it.
export POSTROLL_DERIVED_DATA="${HOME}/Library/Developer/PostRoll"
