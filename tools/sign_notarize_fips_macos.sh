#!/usr/bin/env bash
set -euo pipefail

VERSION="0.5.0"
INSTALLER_IDENTITY="${MACOS_INSTALLER_IDENTITY:-}"
APPLICATION_IDENTITY="${MACOS_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${MACOS_NOTARY_PROFILE:-}"
PACKAGE_DIR="${1:?usage: sign_notarize_fips_macos.sh PACKAGE_DIR}"

for tool in codesign jq pkgutil productsign security shasum xcrun; do
  command -v "$tool" >/dev/null 2>&1 || { printf '%s is required.\n' "$tool" >&2; exit 1; }
done

if [[ -z "$INSTALLER_IDENTITY" ]]; then
  INSTALLER_IDENTITY="$(security find-identity -v -p basic 2>/dev/null | sed -n 's/.*"\(Developer ID Installer:[^"]*\)".*/\1/p' | head -1)"
fi
if [[ -z "$APPLICATION_IDENTITY" ]]; then
  APPLICATION_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)"
fi
[[ -n "$INSTALLER_IDENTITY" ]] || { echo 'No Developer ID Installer identity is available.' >&2; exit 1; }
[[ -n "$APPLICATION_IDENTITY" ]] || { echo 'No Developer ID Application identity is available.' >&2; exit 1; }
[[ -n "$NOTARY_PROFILE" ]] || { echo 'MACOS_NOTARY_PROFILE is required to notarize FIPS packages.' >&2; exit 1; }

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wmapp-fips-sign.XXXXXX")"
cleanup() { rm -rf -- "$WORK_DIR"; }
trap cleanup EXIT INT TERM
PROVENANCE="$WORK_DIR/provenance.json"
printf '{"version":"%s","packages":[' "$VERSION" > "$PROVENANCE"
separator=""

for arch in arm64 x86_64; do
  case "$arch" in
    arm64) expected_sha="3c2252677725a30f4ef68f01935ca6741e57568854d3f71202f2fa90d7239052" ;;
    x86_64) expected_sha="a7883c71039ff591880c38c2421b361103f2ecf20840a9bd496eda13cb3e24c0" ;;
  esac
  package="$PACKAGE_DIR/fips-${VERSION}-macos-${arch}.pkg"
  [[ -f "$package" ]] || { echo "Missing FIPS package: $package" >&2; exit 1; }
  upstream_sha="$(shasum -a 256 "$package" | awk '{print $1}')"
  [[ "$upstream_sha" == "$expected_sha" ]] || {
    echo "FIPS ${arch} upstream checksum mismatch: expected $expected_sha, got $upstream_sha" >&2
    exit 1
  }

  expanded="$WORK_DIR/expanded-${arch}"
  repackaged="$WORK_DIR/repackaged-${arch}.pkg"
  pkgutil --expand-full "$package" "$expanded"
  binaries=(
    "$expanded/Payload/usr/local/bin/fips"
    "$expanded/Payload/usr/local/bin/fipsctl"
    "$expanded/Payload/usr/local/bin/fipstop"
  )
  binary_provenance='[]'
  for binary in "${binaries[@]}"; do
    [[ -f "$binary" ]] || { echo "Missing expected FIPS executable: $binary" >&2; exit 1; }
    original_binary_sha="$(shasum -a 256 "$binary" | awk '{print $1}')"
    codesign --force --strict --options runtime --timestamp --sign "$APPLICATION_IDENTITY" "$binary"
    codesign --verify --strict --verbose=2 "$binary"
    signed_binary_sha="$(shasum -a 256 "$binary" | awk '{print $1}')"
    binary_provenance="$(jq -c \
      --arg path "usr/local/bin/$(basename "$binary")" \
      --arg upstreamSha256 "$original_binary_sha" \
      --arg signedSha256 "$signed_binary_sha" \
      '. + [{path:$path,upstreamSha256:$upstreamSha256,signedSha256:$signedSha256}]' \
      <<< "$binary_provenance")"
  done
  pkgutil --flatten "$expanded" "$repackaged"

  signed="$WORK_DIR/$(basename "$package")"
  productsign --sign "$INSTALLER_IDENTITY" --timestamp "$repackaged" "$signed"
  pkgutil --check-signature "$signed"
  submission="$WORK_DIR/notary-${arch}.json"
  xcrun notarytool submit "$signed" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$submission"
  status="$(jq -r '.status // empty' "$submission")"
  submission_id="$(jq -r '.id // empty' "$submission")"
  [[ "$status" == "Accepted" && -n "$submission_id" ]] || {
    echo "Apple notarization did not accept the FIPS ${arch} package (status: ${status:-unknown})." >&2
    exit 1
  }
  xcrun stapler staple "$signed"
  xcrun stapler validate "$signed"
  pkgutil --check-signature "$signed"
  final_sha="$(shasum -a 256 "$signed" | awk '{print $1}')"
  mv -- "$signed" "$package"

  printf '%s' "$separator" >> "$PROVENANCE"
  jq -n -c \
    --arg architecture "$arch" \
    --arg source "https://github.com/jmcorgan/fips/releases/download/v${VERSION}/fips-${VERSION}-macos-${arch}.pkg" \
    --arg upstreamSha256 "$upstream_sha" \
    --arg signedStapledSha256 "$final_sha" \
    --arg appleSubmissionId "$submission_id" \
    --argjson signedExecutables "$binary_provenance" \
    '{architecture:$architecture,source:$source,upstreamSha256:$upstreamSha256,signedExecutables:$signedExecutables,signedStapledSha256:$signedStapledSha256,appleSubmissionId:$appleSubmissionId,notarizationStatus:"Accepted"}' \
    >> "$PROVENANCE"
  separator=,
done

printf ']}\n' >> "$PROVENANCE"
jq . "$PROVENANCE" > "$PACKAGE_DIR/provenance.json"
printf 'Signed, notarized, and stapled FIPS packages in %s\n' "$PACKAGE_DIR"
