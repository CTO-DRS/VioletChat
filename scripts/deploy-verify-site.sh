#!/usr/bin/env bash
# ============================================================
# DRS NEXORA — deploy the verification site to GitHub Pages
# Source of truth: ./verification-site (this repo)
# Publishing target: public repo CTO-DRS/nexora-verify (Pages)
# Live URL: https://cto-drs.github.io/nexora-verify/
#
# Usage:
#   GITHUB_TOKEN=<your-personal-token> ./scripts/deploy-verify-site.sh "commit message"
#
# Requirements: git, rsync. The token is passed via env var and is
# NEVER written to any file or git config (used inline in the push URL).
# ============================================================
set -euo pipefail

TOKEN="${GITHUB_TOKEN:?GITHUB_TOKEN env var is required (never commit it)}"
MSG="${1:-deploy: sync verification site from drs-nexora}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO_ROOT/verification-site"
TMP="$(mktemp -d)"
DEST_URL="https://${TOKEN}@github.com/CTO-DRS/nexora-verify.git"

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

[ -d "$SRC" ] || { echo "ERROR: $SRC not found" >&2; exit 1; }

# Fresh clone of the publishing repo
git clone --depth 1 "$DEST_URL" "$TMP/repo" 2>/dev/null

# Sync content (delete removed files, keep target's README.md)
rsync -a --delete \
  --exclude '.git' \
  --exclude '.gitignore' \
  --exclude 'README.md' \
  "$SRC"/ "$TMP/repo"/

cd "$TMP/repo"
git add -A
if git diff --cached --quiet; then
  echo "No changes to deploy — site already up to date."
  exit 0
fi
git -c user.name="Z User" -c user.email="z@container" commit -m "$MSG"
git push origin main

echo "Pushed. GitHub Pages will rebuild within ~1 minute."
echo "Live: https://cto-drs.github.io/nexora-verify/"
