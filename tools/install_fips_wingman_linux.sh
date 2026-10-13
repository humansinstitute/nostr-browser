#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "This helper must run as root through WMapp's explicit FIPS activation." >&2
  exit 1
fi

BUNDLE_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
/bin/bash "${BUNDLE_DIR}/install.sh"
/bin/sh "${BUNDLE_DIR}/configure_fips_wingman_linux.sh"

# pkexec records the calling desktop user's uid. Give that user control-socket
# diagnostics without ever reading or exporting either FIPS identity key.
if [ -n "${PKEXEC_UID:-}" ]; then
  CALLING_USER="$(getent passwd "${PKEXEC_UID}" | cut -d: -f1 || true)"
  if [ -n "${CALLING_USER}" ]; then
    usermod -a -G fips "${CALLING_USER}"
  fi
fi
