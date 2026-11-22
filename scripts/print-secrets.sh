#!/usr/bin/env bash
# Prints the GitHub secret values for the files in signing/.
# Expects: signing/distribution.key, signing/distribution.cer, signing/*.mobileprovision
set -euo pipefail
b64() { if base64 --help 2>&1 | grep -q -- "-w"; then base64 -w0 "$1"; else base64 -i "$1" | tr -d '\n'; fi; }
PROFILE=$(ls signing/*.mobileprovision | head -1)
echo "=== SIGNING_KEY_PEM (paste the whole block including BEGIN/END lines) ==="
cat signing/distribution.key
echo
echo "=== SIGNING_CERT_BASE64 ==="
b64 signing/distribution.cer; echo
echo
echo "=== PROVISION_PROFILE_BASE64 (from $PROFILE) ==="
b64 "$PROFILE"; echo
