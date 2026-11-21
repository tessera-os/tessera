#!/bin/sh
# Writes a development-only TIR §29.4.7 signing identity to $1.
# Not a Tessera developer CA identity: nothing trusts it outside development.
# The root private key is discarded; regenerate to rotate.
set -eu
out=$1
openssl=${OPENSSL:-openssl}
[ ! -e "$out" ] || { echo "$out exists" >&2; exit 1; }
umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
"$openssl" genpkey -algorithm ED25519 -out "$work/root.key"
"$openssl" req -new -x509 -key "$work/root.key" -subj "/CN=Tessera Development Only Root" -days 182 \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:0" -addext "keyUsage=critical,keyCertSign" -out "$work/root.pem"
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=codeSigning\n' > "$work/ext"
for pair in ed25519:ED25519 mldsa65:ML-DSA-65; do
  name=${pair%%:*}
  "$openssl" genpkey -algorithm "${pair#*:}" -out "$work/$name.key"
  "$openssl" req -new -key "$work/$name.key" -subj "/CN=LibTessera SDK Development Only" -out "$work/$name.csr"
  "$openssl" x509 -req -in "$work/$name.csr" -CA "$work/root.pem" -CAkey "$work/root.key" -days 180 \
    -extfile "$work/ext" -out "$work/$name.pem" 2>/dev/null
done
der() { "$openssl" x509 -in "$1" -outform DER | base64 | tr -d '\n'; }
key() { "$openssl" pkey -in "$1" -outform DER | base64 | tr -d '\n'; }
root=$(der "$work/root.pem")
printf '{"chain":{"ed25519":["%s","%s"],"mldsa65":["%s","%s"]},"ed25519PrivateKey":"%s","mldsa65PrivateKey":"%s"}\n' \
  "$(der "$work/ed25519.pem")" "$root" "$(der "$work/mldsa65.pem")" "$root" \
  "$(key "$work/ed25519.key")" "$(key "$work/mldsa65.key")" > "$out"
