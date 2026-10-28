#!/bin/zsh
# labels: config, sensitive (writes the API key into a gitignored plist; never prints it)
# Copies META_MODEL_API_KEY into Sightline/Sightline/Secrets.plist so the iOS app can call the
# Meta Model API. The plist is gitignored. Run again whenever the key changes, then rebuild.
#
#   export META_MODEL_API_KEY=...   # or keep it in .env
#   tools/ios_secrets.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEY="${META_MODEL_API_KEY:-}"
if [[ -z "$KEY" && -f "$ROOT/.env" ]]; then
  KEY="$(grep -E '^META_MODEL_API_KEY=' "$ROOT/.env" | head -1 | cut -d= -f2- | tr -d '"'"'"' ')"
fi
if [[ -z "$KEY" ]]; then
  echo "META_MODEL_API_KEY is not set. Run: export META_MODEL_API_KEY=<your key>" >&2
  exit 1
fi
OUT="$ROOT/Sightline/Sightline/Secrets.plist"
if ! git -C "$ROOT" check-ignore -q "$OUT"; then
  echo "Refusing to write: $OUT is not gitignored." >&2
  exit 1
fi
umask 077
cat > "$OUT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>META_MODEL_API_KEY</key>
	<string>${KEY}</string>
</dict>
</plist>
PLIST
plutil -lint "$OUT" >/dev/null
echo "Wrote Sightline/Sightline/Secrets.plist (key length ${#KEY}). Rebuild the app in Xcode."
