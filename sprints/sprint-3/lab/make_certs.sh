#!/usr/bin/env bash
# Sprint 3 lab PKI: a private CA plus ECDSA and RSA certificates for lumina.local.
#
#   ./make_certs.sh                         # CA + lumina-ecdsa + lumina-rsa (skips files that exist)
#   ./make_certs.sh issue NAME [DAYS] [ec|rsa]   # one more lumina.local cert, e.g. for a rotation
#   ./make_certs.sh show                    # summary of every certificate in certs/
#
# Everything lands in lab/certs/, which is gitignored: private keys never enter the repo.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
mkdir -p certs && chmod 755 certs
cd certs

issue() {   # issue NAME DAYS ec|rsa
    local name=$1 days=${2:-200} type=${3:-ec} keyargs
    case "$type" in
        ec)  keyargs=(-newkey ec -pkeyopt ec_paramgen_curve:P-256) ;;
        rsa) keyargs=(-newkey rsa:2048) ;;
        *)   echo "type must be ec or rsa"; exit 1 ;;
    esac
    openssl req -new "${keyargs[@]}" -nodes -keyout "$name.key" -out "$name.csr" -subj "/CN=lumina.local" 2>/dev/null
    openssl x509 -req -in "$name.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -days "$days" -out "$name.crt" \
        -extfile <(printf '%s\n' 'subjectAltName=DNS:lumina.local' 'extendedKeyUsage=serverAuth' \
                                 'basicConstraints=CA:FALSE' 'keyUsage=digitalSignature,keyEncipherment') 2>/dev/null
    rm -f "$name.csr"
    chmod 644 "$name.key"     # lab only: readable by the NGINX Plus container's nginx user
    echo "  issued $name ($type, $days days): $(openssl x509 -in "$name.crt" -noout -serial)"
}

show() {
    for c in *.crt; do
        printf '%-18s %s | %s | %s\n' "$c" \
            "$(openssl x509 -in "$c" -noout -subject | sed 's/subject=//')" \
            "$(openssl x509 -in "$c" -noout -text | grep -oE 'Public Key Algorithm: \S+' | cut -d' ' -f4)" \
            "$(openssl x509 -in "$c" -noout -enddate | cut -d= -f2)"
    done
}

case "${1:-all}" in
    all)
        if [ ! -f ca.crt ]; then
            openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout ca.key -out ca.crt \
                -days 3650 -subj "/CN=Lumina Lab CA" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
            echo "  created Lumina Lab CA"
        fi
        [ -f lumina-ecdsa.crt ] || issue lumina-ecdsa 200 ec
        [ -f lumina-rsa.crt ]   || issue lumina-rsa 200 rsa
        show ;;
    issue) shift; issue "$@" ;;
    show)  show ;;
    *)     echo "usage: $0 [all|issue NAME [DAYS] [ec|rsa]|show]"; exit 1 ;;
esac
