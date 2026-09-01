#!/usr/bin/env bash
# Build a transferable server bundle: the whole repo as git tracks it, PLUS
# the .git directory, PLUS a pre-stamped .update_sha — so a client machine
# that unzips it gets a working git checkout (git pull works) AND a server
# the launcher immediately recognizes as versioned (UPDATE button works,
# no "unknown version" prompt on first run).
#
# Deliberately NOT in the zip (gitignored on purpose):
#   server/.env            — secrets, copy manually to the client
#   xsight_emr.db          — patient data, never leaves this machine
#   ML models & TTS voices — multi-GB, copy separately (see CLAUDE.md
#                            "model drop-in" for the exact file list)
#
# Usage: scripts/make_server_zip.sh [output-dir]   (default: dist/)
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

SHA="$(git rev-parse HEAD)"
SHORT="${SHA:0:8}"
OUT_DIR="${1:-dist}"
ZIP="$OUT_DIR/xsight_server_bundle_$SHORT.zip"

STAGE="$(mktemp -d /tmp/xsight_bundle.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

# 1. Tracked files only — a clean tree with no dev leftovers, exactly what a
#    fresh clone would contain.
git archive HEAD | tar -x -C "$STAGE"

# 2. The git history itself, so `git pull` works on the client machine.
cp -a .git "$STAGE/.git"

# 3. Pre-stamp the version the launcher compares against. Without it the
#    client's first launch reads "version unknown" and prompts a redundant
#    update of code it already has.
mkdir -p "$STAGE/server"
echo "$SHA" > "$STAGE/server/.update_sha"

mkdir -p "$OUT_DIR"
rm -f "$ZIP"
(cd "$STAGE" && zip -qr "$OLDPWD/$ZIP" .)

echo "bundle: $ZIP"
unzip -l "$ZIP" | tail -1
echo "version stamped: $SHORT"
echo "client setup: unzip → copy server/.env + model files → run the launcher"
