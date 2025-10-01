#!/usr/bin/env bash
# lab-ca.sh — minimal offline lab CA helper
# Usage:
#   ./lab-ca.sh init
#   ./lab-ca.sh issue --name demo-login.lab --dns demo-login.lab,assets.demo-login.lab --ip 10.0.100.20
#   ./lab-ca.sh revoke --cert-file issued/demo-login.lab.crt.pem
#   ./lab-ca.sh crl
#
# NOTES:
# - Default workspace: ~/lab-ca (change WORKDIR below)
# - Root key is 4096-bit RSA. Server keys are 2048-bit RSA.
# - Cert validity: root 10y, server 825 days (browser-friendly).
# - Keep lab CA private key inside isolated LAB-DC; do not reuse elsewhere.
set -euo pipefail

WORKDIR="${LAB_CA_DIR:-$HOME/lab-ca}"
OPENSSL_CONF="$WORKDIR/openssl.cnf"
DAYS_SERVER=825
DAYS_ROOT=3650
ROOT_KEY_BITS=4096
SERVER_KEY_BITS=2048
CRL_DAYS=30

# Helper: print usage
usage() {
  cat <<EOF
lab-ca.sh — simple lab CA helper

Commands:
  init                                 Initialize CA directory structure and create root key+cert
  issue --name NAME [--dns DNSLIST] [--ip IPLIST]
                                       Issue server cert for NAME. DNSLIST comma-separated.
  revoke --cert-file PATH              Revoke a cert and add to CRL (optional)
  crl                                  Regenerate current CRL
  help

Examples:
  ./lab-ca.sh init
  ./lab-ca.sh issue --name demo-login.lab --dns demo-login.lab,assets.demo-login.lab --ip 10.0.100.20
  ./lab-ca.sh revoke --cert-file issued/demo-login.lab.crt.pem
EOF
}

# Ensure directories & baseline openssl.cnf template
init_ca() {
  if [[ -d "$WORKDIR" ]]; then
    echo "Workspace $WORKDIR already exists. Continuing (no overwrite)."
  else
    mkdir -p "$WORKDIR"
  fi

  pushd "$WORKDIR" >/dev/null
  mkdir -p certs crl newcerts private requests issued
  chmod 700 private
  touch index.txt
  echo 1000 > serial
  echo 1000 > crlnumber

  cat > "$OPENSSL_CONF" <<'CONF'
# Minimal openssl.cnf for a tiny lab CA
[ ca ]
default_ca = CA_default

[ CA_default ]
dir               = __WORKDIR__
certs             = $dir/certs
crl_dir           = $dir/crl
database          = $dir/index.txt
new_certs_dir     = $dir/newcerts
certificate       = $dir/issued/ca.crt.pem
serial            = $dir/serial
crlnumber         = $dir/crlnumber
private_key       = $dir/private/ca.key.pem
RANDFILE          = $dir/private/.rand
default_days      = 825
default_md        = sha256
preserve          = no
policy            = policy_any

[ policy_any ]
countryName             = optional
stateOrProvinceName     = optional
localityName            = optional
organizationName        = optional
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional

[ req ]
default_bits        = 2048
distinguished_name  = req_distinguished_name
string_mask         = utf8only
default_md          = sha256
prompt              = no

[ req_distinguished_name ]
C  = US
ST = Lab
L  = Lab
O  = ExampleLab
OU = Demo

[ v3_ca ]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, cRLSign, keyCertSign

[ v3_server ]
basicConstraints = CA:FALSE
nsCertType = server
nsComment = "Demo server certificate"
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[ alt_names ]
# filled dynamically when issuing
CONF

  # replace placeholder with actual WORKDIR in config file
  sed -i.bak "s|__WORKDIR__|$WORKDIR|g" "$OPENSSL_CONF"

  # Generate root key and cert
  if [[ -f "$WORKDIR/private/ca.key.pem" ]]; then
    echo "Root key already exists at $WORKDIR/private/ca.key.pem — skipping generation."
  else
    echo "Generating root key ($ROOT_KEY_BITS bits) and self-signed certificate..."
    openssl genpkey -algorithm RSA -out private/ca.key.pem -pkeyopt rsa_keygen_bits:$ROOT_KEY_BITS
    chmod 400 private/ca.key.pem
    openssl req -config "$OPENSSL_CONF" -key private/ca.key.pem -new -x509 -days $DAYS_ROOT -sha256 -extensions v3_ca -out issued/ca.crt.pem -subj "/C=US/ST=Lab/L=Lab/O=ExampleLab/OU=Demo CA/CN=ExampleLab Root CA"
    chmod 444 issued/ca.crt.pem
    echo "Root CA created: $WORKDIR/issued/ca.crt.pem"
  fi

  # Create initial CRL
  openssl ca -config "$OPENSSL_CONF" -gencrl -out crl/ca.crl.pem 2>/dev/null || true

  popd >/dev/null
  echo "CA initialization complete in $WORKDIR"
}

# Helper to create a temporary openssl extfile with SANs
_make_san_extfile() {
  local name="$1"
  local dnslist="$2"
  local iplist="$3"
  local extfile="$WORKDIR/requests/${name}.ext"
  mkdir -p "$WORKDIR/requests"
  {
    echo "subjectAltName = @alt_names"
    echo
    echo "[alt_names]"
    local idx=1
    if [[ -n "$dnslist" ]]; then
      IFS=',' read -ra DNSARR <<< "$dnslist"
      for d in "${DNSARR[@]}"; do
        echo "DNS.$idx = $d"
        idx=$((idx+1))
      done
    fi
    if [[ -n "$iplist" ]]; then
      IFS=',' read -ra IPARR <<< "$iplist"
      for ip in "${IPARR[@]}"; do
        echo "IP.$idx = $ip"
        idx=$((idx+1))
      done
    fi
  } > "$extfile"
  echo "$extfile"
}

# Issue server cert
issue_cert() {
  local name="" dnslist="" iplist=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) name="$2"; shift 2 ;;
      --dns) dnslist="$2"; shift 2 ;;
      --ip) iplist="$2"; shift 2 ;;
      *) echo "Unknown arg $1"; usage; exit 1 ;;
    esac
  done
  if [[ -z "$name" ]]; then echo "Missing --name"; usage; exit 1; fi

  pushd "$WORKDIR" >/dev/null

  # create private key and CSR
  mkdir -p requests issued private
  keyfile="private/${name}.key.pem"
  csr="requests/${name}.csr.pem"
  cert="issued/${name}.crt.pem"

  if [[ -f "$cert" ]]; then
    echo "Cert already exists at $cert — refusing to overwrite."
    popd >/dev/null; return 1
  fi

  echo "Generating server key..."
  openssl genpkey -algorithm RSA -out "$keyfile" -pkeyopt rsa_keygen_bits:$SERVER_KEY_BITS
  chmod 400 "$keyfile"

  echo "Generating CSR (CN=$name)..."
  openssl req -new -key "$keyfile" -out "$csr" -subj "/C=US/ST=Lab/L=Lab/O=ExampleLab/OU=Demo/CN=$name"

  # create extfile with SANs
  extfile=$(_make_san_extfile "$name" "$dnslist" "$iplist")

  echo "Signing certificate for $name (SANs: DNS=$dnslist IP=$iplist) ..."
  openssl ca -config "$OPENSSL_CONF" -extensions v3_server -days $DAYS_SERVER -notext -md sha256 -in "$csr" -out "$cert" -extfile "$extfile" -batch
  chmod 444 "$cert"

  echo "Issued certificate: $cert"
  echo "Server key: $keyfile"
  echo "CA cert: $WORKDIR/issued/ca.crt.pem"

  popd >/dev/null
}

# Revoke cert
revoke_cert() {
  local certfile="$1"
  if [[ -z "$certfile" || ! -f "$certfile" ]]; then
    echo "Please pass a valid issued cert path to revoke."
    exit 1
  fi
  pushd "$WORKDIR" >/dev/null
  echo "Revoking $certfile ..."
  openssl ca -config "$OPENSSL_CONF" -revoke "$certfile"
  openssl ca -config "$OPENSSL_CONF" -gencrl -out crl/ca.crl.pem
  popd >/dev/null
  echo "Revoked and CRL regenerated at $WORKDIR/crl/ca.crl.pem"
}

# Regenerate CRL
regen_crl() {
  pushd "$WORKDIR" >/dev/null
  openssl ca -config "$OPENSSL_CONF" -gencrl -out crl/ca.crl.pem
  popd >/dev/null
  echo "CRL regenerated: $WORKDIR/crl/ca.crl.pem"
}

# CLI dispatch
cmd="${1:-help}"
case "$cmd" in
  init) init_ca ;;
  issue) shift; issue_cert "$@" ;;
  revoke) shift; revoke_cert "$@" ;;
  crl) regen_crl ;;
  help|--help|-h) usage ;;
  *) echo "Unknown command: $cmd"; usage; exit 2 ;;
esac