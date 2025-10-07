#!/usr/bin/env bash
# lab-ca.sh -- Minimal lab CA with DB: init | issue | revoke | crl
# - Initializes a real OpenSSL CA database (index.txt, serial, crlnumber).
# - Issues server certs with SANs using `openssl ca` and a per-issue config
#   that embeds [ v3_server ] and [ alt_names ] (no fragile external extfile).
# - Revokes certs and produces a CRL.
# - POSIX-friendly; works on macOS (LibreSSL) and Linux (OpenSSL).
#
# Usage:
#   ./lab-ca.sh init
#   ./lab-ca.sh issue --name demo-login.lab --dns demo-login.lab,assets.demo-login.lab --ip 10.0.100.20
#   ./lab-ca.sh revoke --cert-file lab-ca/issued/demo-login.lab.crt.pem
#   ./lab-ca.sh crl
#
# Environment overrides (optional):
#   WORKDIR       default: ./lab-ca
#   CA_KEY_BITS   default: 4096
#   SRV_KEY_BITS  default: 2048
#   DAYS          default: 825   (leaf validity)
#   CA_DAYS       default: 3650  (root validity)
#   OPENSSL_BIN   default: openssl
#   SUBJECT_CA    default: /CN=PhishDemo Lab Root CA
#
set -euo pipefail

# Ensure no global OpenSSL config is implicitly loaded (prevents extfile confusion)
export OPENSSL_CONF=/dev/null

# ---- Config ----
WORKDIR="${WORKDIR:-$(pwd)/lab-ca}"
CA_KEY_BITS="${CA_KEY_BITS:-4096}"
SRV_KEY_BITS="${SRV_KEY_BITS:-2048}"
DAYS="${DAYS:-825}"        # ~27 months (lab leaf)
CA_DAYS="${CA_DAYS:-3650}" # 10 years (lab root)
OPENSSL_BIN="${OPENSSL_BIN:-openssl}"
SUBJECT_CA="${SUBJECT_CA:-/CN=PhishDemo Lab Root CA}"

# ---- Helpers ----
log(){ printf '%s\n' "$*" >&2; }
fail(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || fail "Missing dependency: $1"; }
mkp(){ mkdir -p "$1" || fail "mkdir -p $1"; }
sanitize_csv(){ printf '%s' "$1" | tr -d '[:space:]' | sed -e 's/,,*/,/g' -e 's/^,//' -e 's/,$//'; }

base_paths() {
  CA_KEY="$WORKDIR/private/ca.key.pem"
  CA_CERT="$WORKDIR/issued/ca.crt.pem"
  CNF_BASE="$WORKDIR/openssl.cnf"
  DB_DIR="$WORKDIR"
  DB_INDEX="$WORKDIR/index.txt"
  DB_SERIAL="$WORKDIR/serial"
  DB_CRLNUM="$WORKDIR/crlnumber"
  CRL_PEM="$WORKDIR/issued/ca.crl.pem"
}

write_base_cnf() {
  # Minimal CA config; paths point into WORKDIR.
  cat >"$CNF_BASE" <<EOF
[ ca ]
default_ca = CA_default

[ CA_default ]
dir               = $WORKDIR
certs             = \$dir/issued
crl_dir           = \$dir/issued
database          = \$dir/index.txt
new_certs_dir     = \$dir/issued
certificate       = \$dir/issued/ca.crt.pem
serial            = \$dir/serial
crlnumber         = \$dir/crlnumber
crl               = \$dir/issued/ca.crl.pem
private_key       = \$dir/private/ca.key.pem
RANDFILE          = \$dir/.rand

default_md        = sha256
name_opt          = ca_default
cert_opt          = ca_default
default_days      = $DAYS
preserve          = no
policy            = policy_loose
copy_extensions   = none

[ policy_loose ]
countryName             = optional
stateOrProvinceName     = optional
organizationName        = optional
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional
EOF
}

usage() {
  cat <<EOF
Usage:
  $0 init
  $0 issue  --name NAME [--dns a.example,b.example] [--ip 10.0.100.20,203.0.113.45]
  $0 revoke --cert-file lab-ca/issued/NAME.crt.pem
  $0 crl

Notes:
  - CA files live in: $WORKDIR
  - Issued certs:     $WORKDIR/issued
  - Requests/keys:    $WORKDIR/requests
  - Base config:      $WORKDIR/openssl.cnf
EOF
}

cmd_init() {
  need "$OPENSSL_BIN"
  base_paths
  log "Initializing CA at: $WORKDIR"
  mkp "$WORKDIR" "$WORKDIR/private" "$WORKDIR/issued" "$WORKDIR/requests" "$WORKDIR/tmp"

  if [ -f "$CA_KEY" ] || [ -f "$CA_CERT" ]; then
    log "CA material already exists:"
    [ -f "$CA_KEY" ]  && log "  Key : $CA_KEY"
    [ -f "$CA_CERT" ] && log "  Cert: $CA_CERT"
  else
    log "Generating CA key ($CA_KEY_BITS bits)…"
    "$OPENSSL_BIN" genrsa -out "$CA_KEY" "$CA_KEY_BITS" >/dev/null 2>&1 || fail "CA keygen failed"
    chmod 600 "$CA_KEY"
    log "Generating self-signed CA cert ($CA_DAYS days)…"
    "$OPENSSL_BIN" req -x509 -new -nodes -key "$CA_KEY" -sha256 -days "$CA_DAYS" \
      -subj "$SUBJECT_CA" -out "$CA_CERT"
    log "Created:"
    log "  $CA_KEY"
    log "  $CA_CERT"
  fi

  [ -f "$DB_INDEX" ] || : >"$DB_INDEX"
  [ -f "$DB_SERIAL" ] || echo "1000" >"$DB_SERIAL"
  [ -f "$DB_CRLNUM" ] || echo "1000" >"$DB_CRLNUM"

  write_base_cnf
  log "Wrote base OpenSSL config: $CNF_BASE"
  log "Done."
}

cmd_issue() {
  need "$OPENSSL_BIN"
  base_paths

  NAME=""
  DNS_CSV=""
  IP_CSV=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) NAME="${2:-}"; shift 2 ;;
      --dns)  DNS_CSV="${2:-}"; shift 2 ;;
      --ip)   IP_CSV="${2:-}"; shift 2 ;;
      -h|--help) printf 'Usage: %s issue --name NAME [--dns a,b] [--ip x,y]\n' "$0"; exit 0 ;;
      *) fail "Unknown arg: $1" ;;
    esac
  done
  [ -n "$NAME" ] || fail "--name is required"

  [ -f "$CA_KEY" ] && [ -f "$CA_CERT" ] && [ -f "$CNF_BASE" ] || fail "CA not initialized. Run: $0 init"

  DNS_CSV="$(sanitize_csv "${DNS_CSV:-}")"
  IP_CSV="$(sanitize_csv  "${IP_CSV:-}")"

  SRV_KEY="$WORKDIR/requests/$NAME.key.pem"
  SRV_CSR="$WORKDIR/requests/$NAME.csr.pem"
  SRV_CRT="$WORKDIR/issued/$NAME.crt.pem"

  if [ ! -f "$SRV_KEY" ]; then
    log "Generating server key ($SRV_KEY_BITS bits)…"
    "$OPENSSL_BIN" genrsa -out "$SRV_KEY" "$SRV_KEY_BITS" >/dev/null 2>&1 || fail "server keygen failed"
    chmod 600 "$SRV_KEY"
  else
    log "Reusing existing server key: $SRV_KEY"
  fi

  log "Generating CSR for CN=$NAME…"
  "$OPENSSL_BIN" req -new -key "$SRV_KEY" -sha256 -subj "/CN=$NAME" -out "$SRV_CSR"

  # Build per-issue config with embedded v3_server/alt_names
  CNF_ISSUE="$WORKDIR/tmp/$NAME.cnf"
  cp "$CNF_BASE" "$CNF_ISSUE"

  {
    echo
    echo "[ v3_server ]"
    echo "basicConstraints = CA:FALSE"
    echo "keyUsage = critical, digitalSignature, keyEncipherment"
    echo "extendedKeyUsage = serverAuth"
    echo "subjectAltName = @alt_names"
    echo
    echo "[ alt_names ]"
    i=1
    if [ -n "$DNS_CSV" ]; then
      IFS=','; set -f
      for d in $DNS_CSV; do
        [ -n "$d" ] && printf 'DNS.%d = %s\n' "$i" "$d" && i=$((i+1))
      done
      set +f
    fi
    j=1
    if [ -n "$IP_CSV" ]; then
      IFS=','; set -f
      for ip in $IP_CSV; do
        [ -n "$ip" ] && printf 'IP.%d = %s\n' "$j" "$ip" && j=$((j+1))
      done
      set +f
    fi
  } >>"$CNF_ISSUE"

  # If no SANs were provided, add a safe fallback SAN = CN
  if ! grep -qE '^(DNS|IP)\.[0-9]+[[:space:]]*=' "$CNF_ISSUE"; then
    printf '\n# fallback SAN when none specified\n[ alt_names ]\nDNS.1 = %s\n' "$NAME" >> "$CNF_ISSUE"
  fi

  log "Signing certificate (DB-backed)…"
  "$OPENSSL_BIN" ca -batch -notext \
    -config    "$CNF_ISSUE" \
    -extfile   "$CNF_ISSUE" \
    -extensions v3_server \
    -in "$SRV_CSR" -out "$SRV_CRT" -days "$DAYS" -md sha256

  log "Issued:"
  log "  Cert: $SRV_CRT"
  log "  CSR : $SRV_CSR"
  log "  Key : $SRV_KEY"
}

cmd_revoke() {
  need "$OPENSSL_BIN"
  base_paths

  CERT_FILE=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --cert-file) CERT_FILE="${2:-}"; shift 2 ;;
      -h|--help) printf 'Usage: %s revoke --cert-file lab-ca/issued/NAME.crt.pem\n' "$0"; exit 0 ;;
      *) fail "Unknown arg: $1" ;;
    esac
  done
  [ -n "$CERT_FILE" ] || fail "--cert-file is required"
  [ -f "$CNF_BASE" ] || fail "Missing $CNF_BASE (run init)"
  [ -f "$CERT_FILE" ] || fail "Cert not found: $CERT_FILE"

  log "Revoking certificate: $CERT_FILE"
  "$OPENSSL_BIN" ca -config "$CNF_BASE" -revoke "$CERT_FILE" -crl_reason keyCompromise
  log "Revoked. Now generate CRL with: $0 crl"
}

cmd_crl() {
  need "$OPENSSL_BIN"
  base_paths
  [ -f "$CNF_BASE" ] || fail "Missing $CNF_BASE (run init)"
  log "Generating CRL: $CRL_PEM"
  "$OPENSSL_BIN" ca -config "$CNF_BASE" -gencrl -out "$CRL_PEM"
  log "CRL written to $CRL_PEM"
}

main() {
  [ $# -gt 0 ] || { usage; exit 1; }
  cmd="$1"; shift || true
  case "$cmd" in
    init)   cmd_init "$@";;
    issue)  cmd_issue "$@";;
    revoke) cmd_revoke "$@";;
    crl)    cmd_crl "$@";;
    -h|--help) usage;;
    *) usage; exit 1;;
  esac
}
main "$@"