#!/usr/bin/env bash
# Creates a private key and a Certificate Signing Request (CSR) for an
# "Apple Distribution" certificate — no Mac needed. Works in Git Bash, WSL or Linux.
#
#   ./scripts/make-signing-request.sh you@example.com "Your Name"
#
# Upload signing/distribution.csr at developer.apple.com → Certificates → "+" →
# "Apple Distribution". Download the resulting distribution.cer and put it into signing/.
# Then run ./scripts/print-secrets.sh to get the values for the GitHub secrets.
set -euo pipefail
EMAIL="${1:?usage: $0 <apple-id-email> <your name>}"
NAME="${2:-BahnMap Developer}"
mkdir -p signing
if [ -f signing/distribution.key ]; then
  echo "signing/distribution.key already exists — not overwriting it." >&2
  exit 1
fi
openssl genrsa -out signing/distribution.key 2048
# MSYS_NO_PATHCONV stops Git Bash on Windows from mangling the "/emailAddress=..." subject.
MSYS_NO_PATHCONV=1 openssl req -new -key signing/distribution.key -out signing/distribution.csr \
  -subj "/emailAddress=${EMAIL}/CN=${NAME}/C=DE"
echo
echo "Created signing/distribution.key (keep it secret!) and signing/distribution.csr."
echo "Next: upload signing/distribution.csr to Apple (see docs/SETUP.md, step 2)."
