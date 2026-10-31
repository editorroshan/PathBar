#!/bin/bash
# One-time setup (install.sh runs it for you): creates a personal code-signing certificate,
# "PathBar Local Signing", in your login keychain. PathBar is signed with it, so macOS
# recognises every new build as the same app and keeps its Accessibility permission.
# Without it, each update looks like a new app and the permission has to be given again.
#
# The certificate is self-made and only used on this Mac. It is not trusted system-wide
# and needs no admin password. Remove it any time with:
#   security delete-identity -c "PathBar Local Signing"
set -euo pipefail

NAME="PathBar Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$NAME\""; then
  echo "\"$NAME\" already exists. Nothing to do."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
PASS="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/identity.p12" -passout "pass:$PASS" 2>/dev/null
# Only Apple's codesign tool may use the key.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null

# Try it once now. If macOS asks whether codesign may use the key, enter your
# Mac password and click "Always Allow" (it won't ask again).
printf 'int main(void){return 0;}' > "$TMP/t.c"
clang "$TMP/t.c" -o "$TMP/t" 2>/dev/null
if codesign --force --sign "$NAME" "$TMP/t" 2>/dev/null && codesign -dr - "$TMP/t" 2>&1 | grep -q 'certificate leaf'; then
  echo "Created \"$NAME\" in your login keychain."
else
  echo "The certificate was created but signing with it failed. Run: codesign -s \"$NAME\" /path/to/app to see why."
  exit 1
fi
