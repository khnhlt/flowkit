#!/usr/bin/env bash
# Fetch the reCAPTCHA Enterprise client the extension injects into flow.google.com.
#
# flow.google.com no longer loads grecaptcha into the page, and its
# trusted-types CSP blocks <script src> from google.com / gstatic.com, so the
# extension injects both files from its own chrome-extension:// origin
# (extension/content.js). They are Google's code, so they are fetched here
# rather than committed:
#
#   recaptcha_enterprise.js  loader   https://www.google.com/recaptcha/enterprise.js?render=explicit
#   recaptcha__en.js         client   https://www.gstatic.com/recaptcha/releases/<release>/recaptcha__en.js
#
# The loader names the client release and its sha384 SRI; the client is
# checked against that hash before anything is replaced. Google rotates the
# release, so re-run this (then reload the extension) if generations start
# failing PUBLIC_ERROR_UNUSUAL_ACTIVITY while the Flow UI itself still works.
#
# Usage: scripts/fetch_recaptcha.sh [extension_dir]
set -euo pipefail

EXT_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)/extension}"
LOADER_URL="https://www.google.com/recaptcha/enterprise.js?render=explicit"

for tool in curl openssl; do
    command -v "$tool" >/dev/null || { echo "ERROR: $tool is required" >&2; exit 1; }
done
[ -d "$EXT_DIR" ] || { echo "ERROR: extension dir not found: $EXT_DIR" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fsSL "$LOADER_URL" -o "$TMP/recaptcha_enterprise.js"

CLIENT_URL="$(grep -oE "https://www\.gstatic\.com/recaptcha/releases/[A-Za-z0-9_-]+/recaptcha__en\.js" "$TMP/recaptcha_enterprise.js" | head -1 || true)"
SRI="$(grep -oE "sha384-[A-Za-z0-9+/=]+" "$TMP/recaptcha_enterprise.js" | head -1 || true)"
if [ -z "$CLIENT_URL" ] || [ -z "$SRI" ]; then
    echo "ERROR: loader did not name a client release + integrity hash; its format may have changed" >&2
    exit 1
fi
RELEASE="$(echo "$CLIENT_URL" | sed -E 's#.*/releases/([^/]+)/.*#\1#')"

curl -fsSL "$CLIENT_URL" -o "$TMP/recaptcha__en.js"
ACTUAL="sha384-$(openssl dgst -sha384 -binary "$TMP/recaptcha__en.js" | openssl base64 -A)"
if [ "$ACTUAL" != "$SRI" ]; then
    echo "ERROR: client integrity mismatch for release $RELEASE" >&2
    echo "  expected $SRI" >&2
    echo "  got      $ACTUAL" >&2
    exit 1
fi

PREVIOUS="$(grep -oE "releases/[A-Za-z0-9_-]+" "$EXT_DIR/recaptcha_enterprise.js" 2>/dev/null | head -1 | sed 's#releases/##' || true)"
mv "$TMP/recaptcha_enterprise.js" "$EXT_DIR/recaptcha_enterprise.js"
mv "$TMP/recaptcha__en.js" "$EXT_DIR/recaptcha__en.js"

if [ -z "$PREVIOUS" ]; then
    echo "  Fetched reCAPTCHA release $RELEASE"
elif [ "$PREVIOUS" = "$RELEASE" ]; then
    echo "  reCAPTCHA release $RELEASE (unchanged)"
else
    echo "  reCAPTCHA release $PREVIOUS -> $RELEASE — reload the extension at chrome://extensions"
fi
