#!/bin/sh
# Sprint 7 lab PKI. Run by "./lab.sh pki" inside the nginx:mainline image (OpenSSL 3.5),
# so every learner gets the same certificates whatever the host's OpenSSL is.
# Writes lab/certs/ (gitignored: it holds private keys).
#
#   internal-ca   Tidewater Internal CA: the edge's server certificate, the ledger's server
#                 certificate, and the edge's client certificate for talking to the ledger
#   partner-ca    Tidewater Partner CA: one client certificate per partner, and its CRL
#   rogue-ca      a CA nobody trusts, used to forge an "acme" certificate
set -e
D=/certs
cd "$D"
rm -rf ./*

ec() { openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$1.key" 2>/dev/null; }

mkca() { # name "subject"
    mkdir -p "$1.db/new"; : > "$1.db/index.txt"; echo 1000 > "$1.db/serial"; echo 1000 > "$1.db/crlnumber"
    ec "$1"
    openssl req -x509 -new -key "$1.key" -out "$1.crt" -days 3650 -subj "$2" \
        -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign 2>/dev/null
    cat > "$1.db/ca.cnf" <<C
[ca]
default_ca = this
[this]
database        = $D/$1.db/index.txt
new_certs_dir   = $D/$1.db/new
serial          = $D/$1.db/serial
crlnumber       = $D/$1.db/crlnumber
certificate     = $D/$1.crt
private_key     = $D/$1.key
default_md      = sha256
default_days    = 365
default_crl_days = 30
policy          = any
copy_extensions = copy
unique_subject  = no
[any]
commonName             = supplied
organizationName       = optional
organizationalUnitName = optional
C
}

issue() { # ca name "subject" "subjectAltName" usage
    ec "$2"
    openssl req -new -key "$2.key" -out "$2.csr" -subj "$3" -addext "subjectAltName=$4" -addext "extendedKeyUsage=$5" 2>/dev/null
    openssl ca -batch -notext -config "$1.db/ca.cnf" -in "$2.csr" -out "$2.crt" 2>/dev/null
    rm -f "$2.csr"
}

mkca internal-ca "/O=Tidewater Logistics/CN=Tidewater Internal CA"
mkca partner-ca  "/O=Tidewater Logistics/CN=Tidewater Partner CA"
mkca rogue-ca    "/O=Definitely Legit/CN=Rogue CA"

issue internal-ca edge   "/O=Tidewater Logistics/CN=localhost"      "DNS:localhost,DNS:s7-edge,IP:127.0.0.1" serverAuth
issue internal-ca ledger "/O=Tidewater Logistics/CN=ledger.internal" "DNS:ledger.internal"                   serverAuth
issue internal-ca edge-client "/O=Tidewater Logistics/OU=Edge/CN=tidewater-edge" "DNS:tidewater-edge"        clientAuth

issue partner-ca acme    "/O=Acme Freight/OU=Integrations/CN=acme"  "DNS:api.acme.example,URI:spiffe://partners.tidewater/acme" clientAuth
issue partner-ca globex  "/O=Globex Shipping/CN=globex"             "DNS:edi.globex.example,email:edi@globex.example"          clientAuth
issue partner-ca initech "/O=Initech Cargo/CN=initech"              "DNS:api.initech.example"                                 clientAuth

# Initech's contract ended: revoked, and on the CRL
openssl ca -config partner-ca.db/ca.cnf -revoke initech.crt -crl_reason cessationOfOperation 2>/dev/null
openssl ca -config partner-ca.db/ca.cnf -gencrl -out partner-ca.crl 2>/dev/null

# A forgery: same subject as Acme's, signed by the rogue CA
issue rogue-ca fake-acme "/O=Acme Freight/OU=Integrations/CN=acme" "DNS:api.acme.example" clientAuth

# The ledger's impostor: a server certificate for the same name, signed by the rogue CA
issue rogue-ca impostor "/O=Tidewater Logistics/CN=ledger.internal" "DNS:ledger.internal" serverAuth

chmod 644 ./*.crt ./*.crl
chmod 640 ./*.key
for f in edge ledger edge-client acme globex initech fake-acme impostor; do
    printf '  %-12s %s  (issuer: %s)\n' "$f" "$(openssl x509 -in $f.crt -noout -subject -nameopt RFC2253 | sed 's/subject=//')" \
        "$(openssl x509 -in $f.crt -noout -issuer -nameopt RFC2253 | sed 's/.*CN=//')"
done
