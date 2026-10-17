#!/usr/bin/env bash
# Create an opt-in, self-signed local code-signing identity so rebuilds keep the same code
# identity (macOS keeps audio-capture and Automation grants instead of re-prompting).
# Env: DRY_RUN (any value except 0/false/no/off), KEYCHAIN_PASSWORD (for the partition-list step;
#      prompted when on a terminal, skipped with a note otherwise).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "$REPO/scripts/lib.sh"

NAME="$DEFAULT_SIGNING_NAME"
KEYCHAIN=""
VALID_DAYS=3650

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--name NAME] [--keychain PATH]

Creates a self-signed code-signing certificate + private key (10 years) and imports it
into a keychain (default: your login keychain). The certificate is NOT marked trusted and
no trust settings are changed: codesign works with an untrusted identity, and a stable
identity is what keeps your permission grants across rebuilds.
Idempotent: if an identity named NAME already exists, nothing is changed.
  --name NAME      identity common name (default: "$DEFAULT_SIGNING_NAME")
  --keychain PATH  target keychain (default: login keychain)
Remove it later:   security delete-identity -c "NAME"
DRY_RUN=1 prints the plan without doing anything.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) [[ $# -ge 2 ]] || { echo "error: --name needs a value" >&2; exit 2; }; NAME="$2"; shift 2 ;;
    --keychain) [[ $# -ge 2 ]] || { echo "error: --keychain needs a value" >&2; exit 2; }; KEYCHAIN="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || die "macOS only"
[[ -n "$NAME" ]] || die "--name is empty"
[[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9\ ._-]*$ ]] || die "--name may only contain letters, digits, space, . _ - (got: '$NAME')"
if [[ -z "$KEYCHAIN" ]]; then
  KEYCHAIN="$(security default-keychain -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')"
  [[ -n "$KEYCHAIN" ]] || die "could not determine the default keychain; pass --keychain"
fi
[[ -e "$KEYCHAIN" ]] || is_dry_run || die "keychain not found: $KEYCHAIN"

# Exact common-name match (find-identity lists invalid/untrusted identities too without -v).
has_identity() {
  [[ -e "$KEYCHAIN" ]] || return 1
  security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -qF "\"$NAME\""
}

if has_identity; then
  echo "identity \"$NAME\" already exists in $KEYCHAIN; nothing to do."
  exit 0
fi

echo "This will create a self-signed code-signing identity \"$NAME\" (valid $VALID_DAYS days)"
echo "and import it into: $KEYCHAIN"
echo "It is not trusted and no trust settings change. To remove it later:"
echo "  security delete-identity -c \"$NAME\" \"$KEYCHAIN\""

if is_dry_run; then
  echo "[dry-run] openssl req -x509 (CN=$NAME, keyUsage=digitalSignature, extendedKeyUsage=codeSigning)"
  echo "[dry-run] security import <p12> -k $KEYCHAIN -T /usr/bin/codesign"
  echo "[dry-run] security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k <password> $KEYCHAIN"
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wo-signing.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"
P12_PASS="$(openssl rand -hex 16)"

cat > "$WORK/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days "$VALID_DAYS" \
  -config "$WORK/openssl.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null \
  || die "openssl could not create the certificate"
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$NAME" -passout "pass:$P12_PASS" -out "$WORK/id.p12" 2>/dev/null \
  || die "openssl could not build the p12"

security import "$WORK/id.p12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign >/dev/null \
  || die "security import failed"
echo "imported \"$NAME\" into $KEYCHAIN"

# Lets codesign use the key without a per-build prompt. Needs the keychain password.
KC_PASS="${KEYCHAIN_PASSWORD-}"
if [[ -z "$KC_PASS" && -t 0 ]]; then
  read -r -s -p "Password for $KEYCHAIN (Enter to skip): " KC_PASS; echo
fi
if [[ -n "$KC_PASS" ]]; then
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KEYCHAIN" >/dev/null 2>&1 \
    || echo "warning: set-key-partition-list failed (wrong password?); codesign may prompt once. Choose 'Always Allow'." >&2
else
  echo "note: skipped set-key-partition-list; the first build may prompt for keychain access. Choose 'Always Allow'."
fi

has_identity || die "identity not found after import"
echo "done. build.sh now signs with \"$NAME\" automatically."
