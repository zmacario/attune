#!/bin/bash
# Creates a self-signed code-signing certificate named "Attune Local" in your
# login keychain, so that rebuilding the app keeps the permissions you granted it.
#
# Why this is needed: an ad-hoc signature's designated requirement is the hash of the
# binary, so every rebuild looks like a brand-new app to macOS and the Media & Apple
# Music permission is requested again. A certificate anchors that requirement to itself.
#
# This touches your keychain and your certificate trust settings. Read it before running.
# You will be asked to approve the trust change.
set -euo pipefail

NAME="Attune Local"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "Already present:"
    security find-identity -v -p codesigning | grep "$NAME"
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# The PKCS#12 password is a throwaway: it only carries the private key from openssl into
# the keychain, and is discarded with the temp directory. It must not be empty — LibreSSL
# and macOS's `security` disagree on how an empty password is encoded for the file's MAC,
# and the import fails with "MAC verification failed".
PASSWORD=$(openssl rand -hex 16)

echo "Generating a 10-year self-signed code-signing certificate…"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

openssl pkcs12 -export -out "$WORK/identity.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -passout "pass:$PASSWORD" 2>/dev/null

echo "Importing into your login keychain…"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign

echo "Marking it trusted for code signing — macOS will ask you to approve this."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo
if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "Done. build.sh will pick this up automatically:"
    security find-identity -v -p codesigning | grep "$NAME"
    echo
    echo "The first build may ask for permission to use the key — choose Always Allow."
else
    echo "The certificate did not come out valid for code signing." >&2
    echo "Use Keychain Access instead — see README → Permissões." >&2
    exit 1
fi
