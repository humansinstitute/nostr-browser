#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/wmapp"
KEYSTORE_PATH="${WMAPP_ANDROID_KEYSTORE:-$CONFIG_DIR/android-release.jks}"
KEY_ALIAS="${WMAPP_ANDROID_KEY_ALIAS:-wmapp}"
KEYCHAIN_SERVICE="${WMAPP_ANDROID_KEYCHAIN_SERVICE:-wmapp-android-release}"
KEYCHAIN_ACCOUNT="${WMAPP_ANDROID_KEYCHAIN_ACCOUNT:-wmapp}"

KEYTOOL_BIN="${JAVA_HOME:+$JAVA_HOME/bin/keytool}"
if [[ -z "$KEYTOOL_BIN" || ! -x "$KEYTOOL_BIN" ]]; then
  if [[ -x "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/keytool" ]]; then
    KEYTOOL_BIN="/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/keytool"
  else
    KEYTOOL_BIN="$(command -v keytool || true)"
  fi
fi
[[ -n "$KEYTOOL_BIN" && -x "$KEYTOOL_BIN" ]] || {
  echo "A working JDK keytool is required." >&2
  exit 1
}
command -v openssl >/dev/null 2>&1 || {
  echo "openssl is required." >&2
  exit 1
}
command -v security >/dev/null 2>&1 || {
  echo "macOS Keychain's security command is required by this setup helper." >&2
  exit 1
}

if [[ -e "$KEYSTORE_PATH" ]]; then
  echo "Refusing to overwrite existing keystore: $KEYSTORE_PATH" >&2
  exit 1
fi

mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

WMAPP_KEYSTORE_SETUP_PASSWORD="$(openssl rand -base64 32)"
export WMAPP_KEYSTORE_SETUP_PASSWORD
cleanup_failed_setup() {
  unset WMAPP_KEYSTORE_SETUP_PASSWORD
  if [[ -e "$KEYSTORE_PATH" ]]; then
    rm -f -- "$KEYSTORE_PATH"
  fi
}
trap cleanup_failed_setup ERR INT TERM

"$KEYTOOL_BIN" -genkeypair \
  -keystore "$KEYSTORE_PATH" \
  -storetype PKCS12 \
  -storepass:env WMAPP_KEYSTORE_SETUP_PASSWORD \
  -keypass:env WMAPP_KEYSTORE_SETUP_PASSWORD \
  -alias "$KEY_ALIAS" \
  -keyalg RSA \
  -keysize 4096 \
  -validity 10000 \
  -dname "CN=WMAPP Android Release, O=Wingman Be Free"

chmod 600 "$KEYSTORE_PATH"
printf '%s\n' "$WMAPP_KEYSTORE_SETUP_PASSWORD" | security add-generic-password -U \
  -a "$KEYCHAIN_ACCOUNT" \
  -s "$KEYCHAIN_SERVICE" \
  -w >/dev/null

trap - ERR INT TERM
unset WMAPP_KEYSTORE_SETUP_PASSWORD

echo "Created durable WMAPP release keystore: $KEYSTORE_PATH"
echo "Stored its password in macOS Keychain service: $KEYCHAIN_SERVICE"
echo "Public certificate fingerprint:"
WMAPP_ANDROID_STORE_PASSWORD="$(security find-generic-password -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" -w)"
export WMAPP_ANDROID_STORE_PASSWORD
"$KEYTOOL_BIN" -list -v \
  -keystore "$KEYSTORE_PATH" \
  -storepass:env WMAPP_ANDROID_STORE_PASSWORD \
  -alias "$KEY_ALIAS" | sed -n '/SHA256:/p'
unset WMAPP_ANDROID_STORE_PASSWORD
