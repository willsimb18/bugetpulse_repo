#!/usr/bin/env bash
# Point app/.env at the dev or the production Supabase project.
#
#   ./use-env.sh dev     work against the throwaway database
#   ./use-env.sh prod    work against real household data
#
# Vite watches .env and restarts itself, so a running `npm run dev`
# picks this up without being restarted by hand.
set -euo pipefail

cd "$(dirname "$0")"

target="${1:-}"
case "$target" in
  dev|prod) ;;
  *) echo "usage: ./use-env.sh dev|prod" >&2; exit 1 ;;
esac

src=".env.$target"
if [ ! -f "$src" ]; then
  echo "missing $src — create it next to package.json" >&2
  exit 1
fi

cp "$src" .env

# Echo the URL, never the key, so it is obvious which database is live.
printf '.env -> %s\n' "$src"
grep '^VITE_SUPABASE_URL=' .env
