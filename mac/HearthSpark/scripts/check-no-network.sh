#!/bin/bash
# Fails if a Hearth Spark binary links any networking API.
#
#   scripts/check-no-network.sh path/to/binary
#
# Backs the promise "Hearth Spark doesn't use the internet at all". The app can't use
# the App Sandbox to have macOS enforce it (Full Disk Access needs the app outside the
# sandbox), so the build checks instead: no networking frameworks linked, and no
# networking functions or classes referenced. AirDrop isn't affected — macOS performs
# the transfer itself, outside the app.
set -euo pipefail
BIN="$1"

FRAMEWORKS='/(Network|CFNetwork|WebKit)\.framework/'
SYMBOLS='URLSession|NSURLConnection|NWConnection|NWListener|NWBrowser|CFSocket|CFStreamCreatePairWithSocket|CFReadStreamCreateWithFTPURL|^_socket$|^_connect$|^_getaddrinfo$|^_gethostbyname|^_sendto$|^_recvfrom$'

linked="$(otool -L "$BIN" | grep -E "$FRAMEWORKS" || true)"
if [ -n "$linked" ]; then
  echo "✘ $BIN links a networking framework:" >&2
  echo "$linked" >&2
  exit 1
fi

found="$(nm -u "$BIN" | sed 's/^ *//' | grep -E "$SYMBOLS" || true)"
if [ -n "$found" ]; then
  echo "✘ $BIN references networking APIs:" >&2
  echo "$found" >&2
  exit 1
fi

echo "✔ No networking APIs in $(basename "$BIN")"
