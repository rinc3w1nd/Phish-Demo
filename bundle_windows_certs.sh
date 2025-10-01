#!/usr/bin/env bash
# bundle_windows_certs.sh
# Usage:
#   ./bundle_windows_certs.sh --root /path/to/root.crt [--inter /path/to/inter.crt] [--out /path/to/outdir]
#
# Produces: root.der, inter.der (if provided), chain.pem, chain.p7b (DER)
#
set -euo pipefail

print_usage() {
  cat <<EOF
Usage:
  $0 --root /path/to/root.crt [--inter /path/to/inter.crt] [--out /path/to/outdir]

Notes:
  - Input certs should be PEM (-----BEGIN CERTIFICATE-----). If they are .crt you can still pass them.
  - Output files will be created in --out (default ./win-certs).
  - After running, use the PowerShell/certutil commands printed below (Admin) to install them on Windows.
EOF
}

ROOT=""
INTER=""
OUTDIR="./win-certs"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="$2"; shift 2 ;;
    --inter) INTER="$2"; shift 2 ;;
    --out) OUTDIR="$2"; shift 2 ;;
    -h|--help) print_usage; exit 0 ;;
    *) echo "Unknown arg: $1"; print_usage; exit 1 ;;
  esac
done

if [[ -z "$ROOT" ]]; then
  echo "Error: --root is required"
  print_usage
  exit 1
fi

if [[ ! -f "$ROOT" ]]; then
  echo "Error: root file not found: $ROOT"
  exit 1
fi

if [[ -n "$INTER" && ! -f "$INTER" ]]; then
  echo "Error: intermediate file not found: $INTER"
  exit 1
fi

mkdir -p "$OUTDIR"
ROOT_BASENAME=$(basename "$ROOT")
ROOT_PEM="$OUTDIR/$(basename "${ROOT_BASENAME%.*}").pem"
ROOT_DER="$OUTDIR/$(basename "${ROOT_BASENAME%.*}").der"
CHAIN_PEM="$OUTDIR/chain.pem"
CHAIN_P7B="$OUTDIR/chain.p7b"

# Normalize input to PEM (strip if necessary)
# If the file already contains PEM header, copy; otherwise try to convert
if grep -q "BEGIN CERTIFICATE" "$ROOT"; then
  cp "$ROOT" "$ROOT_PEM"
else
  # try to convert DER->PEM
  openssl x509 -inform der -in "$ROOT" -out "$ROOT_PEM"
fi

# optional intermediate
if [[ -n "$INTER" ]]; then
  INTER_BASENAME=$(basename "$INTER")
  INTER_PEM="$OUTDIR/$(basename "${INTER_BASENAME%.*}").pem"
  INTER_DER="$OUTDIR/$(basename "${INTER_BASENAME%.*}").der"
  if grep -q "BEGIN CERTIFICATE" "$INTER"; then
    cp "$INTER" "$INTER_PEM"
  else
    openssl x509 -inform der -in "$INTER" -out "$INTER_PEM"
  fi
fi

# Generate DER versions (Windows-friendly)
openssl x509 -outform der -in "$ROOT_PEM" -out "$ROOT_DER"
chmod 644 "$ROOT_DER"

if [[ -n "$INTER" ]]; then
  openssl x509 -outform der -in "$INTER_PEM" -out "$INTER_DER"
  chmod 644 "$INTER_DER"
fi

# Create PEM chain: order matters: leaf (not included), intermediate(s) ..., root last
# Since this is for root+intermediate bundling, we simply concatenate intermediate then root
> "$CHAIN_PEM"
if [[ -n "$INTER" ]]; then
  cat "$INTER_PEM" >> "$CHAIN_PEM"
fi
cat "$ROOT_PEM" >> "$CHAIN_PEM"

# Create PKCS#7 bundle in DER format (chain.p7b)
# openssl crl2pkcs7 takes certfile arguments (it expects certs in files)
if [[ -n "$INTER" ]]; then
  openssl crl2pkcs7 -nocrl -certfile "$INTER_PEM" -certfile "$ROOT_PEM" -outform DER -out "$CHAIN_P7B"
else
  # single cert p7b - include root only
  openssl crl2pkcs7 -nocrl -certfile "$ROOT_PEM" -outform DER -out "$CHAIN_P7B"
fi
chmod 644 "$CHAIN_P7B"

echo "Created files in: $OUTDIR"
echo "  - Root PEM:  $ROOT_PEM"
echo "  - Root DER:  $ROOT_DER"
if [[ -n "$INTER" ]]; then
  echo "  - Inter PEM: $INTER_PEM"
  echo "  - Inter DER: $INTER_DER"
fi
echo "  - Chain PEM: $CHAIN_PEM"
echo "  - Chain PKCS7 (DER): $CHAIN_P7B"
echo
cat <<'TEXT'

INSTALL INSTRUCTIONS (Windows) — run as Administrator
=====================================================

Option A — Import via certutil (console) into LocalMachine stores:
  # Import Root into Trusted Root Certification Authorities (LocalMachine\Root)
  certutil -addstore -f Root "root.der"

  # If you have an intermediate, import it into Intermediate Certification Authorities (LocalMachine\CA)
  certutil -addstore -f CA "inter.der"

  # Example (PowerShell prompt as Admin):
  certutil -addstore -f Root "C:\path\to\root.der"
  certutil -addstore -f CA   "C:\path\to\inter.der"

Option B — Import via PowerShell (requires Admin):
  # Import root
  Import-Certificate -FilePath "C:\path\to\root.der" -CertStoreLocation Cert:\LocalMachine\Root

  # Import intermediate (if present)
  Import-Certificate -FilePath "C:\path\to\inter.der" -CertStoreLocation Cert:\LocalMachine\CA

Option C — GUI (Certificate Import Wizard):
  - Copy 'chain.p7b' to the Windows machine.
  - Double-click chain.p7b → Install Certificate → Choose 'Local Machine' → Place all certificates in the
    appropriate store or let Windows choose (it will usually populate Root/Intermediate automatically).
  - Verify in MMC → Certificates (Local Computer) → Trusted Root Certification Authorities / Intermediate Certification Authorities.

Notes:
  - Admin privileges required to modify machine stores.
  - After install, restart browsers if necessary.
  - To remove test root later:
      certutil -delstore Root "ExampleLab Root CA"   # or use thumbprint
      # or in PowerShell remove via Cert:\ PSDrive and Remove-Item

TEXT

echo
echo "Example (PowerShell) commands to run on the Windows VM (adjust paths):"
if [[ -n "$INTER" ]]; then
  echo
  echo "  Import-Certificate -FilePath C:\\path\\to\\$(basename "$ROOT_DER") -CertStoreLocation Cert:\\LocalMachine\\Root"
  echo "  Import-Certificate -FilePath C:\\path\\to\\$(basename "$INTER_DER") -CertStoreLocation Cert:\\LocalMachine\\CA"
  echo
  echo "OR (certutil):"
  echo "  certutil -addstore -f Root C:\\path\\to\\$(basename "$ROOT_DER")"
  echo "  certutil -addstore -f CA   C:\\path\\to\\$(basename "$INTER_DER")"
else
  echo
  echo "  Import-Certificate -FilePath C:\\path\\to\\$(basename "$ROOT_DER") -CertStoreLocation Cert:\\LocalMachine\\Root"
  echo
  echo "OR (certutil):"
  echo "  certutil -addstore -f Root C:\\path\\to\\$(basename "$ROOT_DER")"
fi

echo
echo "Done."