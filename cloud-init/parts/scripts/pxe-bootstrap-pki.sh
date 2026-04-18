#!/usr/bin/env bash
# Self-signed CA + server cert + client cert for Matchbox mTLS.
# Idempotent via sentinel.
set -euo pipefail

SENTINEL=/etc/matchbox/.pki-done
if [[ -f "$SENTINEL" ]]; then
    echo "pki: already bootstrapped"
    exit 0
fi

DIR=/etc/matchbox
mkdir -p "$DIR"
cd "$DIR"

if [[ -f /etc/pxe/pki.env ]]; then
    # shellcheck source=/dev/null
    source /etc/pxe/pki.env
fi
: "${PI_LAB_IP:?PI_LAB_IP required}"
: "${HOSTNAME:?HOSTNAME required}"
: "${LAB_DOMAIN:?LAB_DOMAIN required}"

openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
    -subj "/CN=matchbox-ca" -out ca.crt

openssl genrsa -out server.key 4096
openssl req -new -key server.key -subj "/CN=pxe.${LAB_DOMAIN}" -out server.csr
cat > server.ext <<EOF
subjectAltName = DNS:pxe.${LAB_DOMAIN},DNS:${HOSTNAME},IP:${PI_LAB_IP}
extendedKeyUsage = serverAuth
EOF
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out server.crt -days 3650 -sha256 -extfile server.ext

openssl genrsa -out client.key 4096
openssl req -new -key client.key -subj "/CN=terraform" -out client.csr
cat > client.ext <<EOF
extendedKeyUsage = clientAuth
EOF
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out client.crt -days 3650 -sha256 -extfile client.ext

chmod 600 ca.key server.key client.key
chmod 644 ca.crt server.crt client.crt
chown -R matchbox:matchbox "$DIR"
chmod 600 "$DIR"/ca.key "$DIR"/server.key

tar czf /root/matchbox-client-bundle.tar.gz -C "$DIR" ca.crt client.crt client.key
chmod 600 /root/matchbox-client-bundle.tar.gz

rm -f "$DIR"/server.csr "$DIR"/server.ext "$DIR"/client.csr "$DIR"/client.ext "$DIR"/ca.srl
touch "$SENTINEL"
echo "pki: client bundle at /root/matchbox-client-bundle.tar.gz"
