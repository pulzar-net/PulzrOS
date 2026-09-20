#!/usr/bin/env bash
#
# Sign a built image, so a gateway can tell it is ours.
#
#   tools/sign-firmware.sh <image> [board] [version]
#
# Writes <image>.parkeze.json beside the image. That file is what travels with
# the image and what parkeze-firmware verifies before anything is flashed.
#
# ── THE FORMAT, AND WHY IT IS THIS ONE ─────────────────────────────────────
#
#   {"manifest":"<base64 of a small JSON object>","signature":"<base64>"}
#
# Deliberately the same envelope an adoption bundle uses, because the gateway
# already verifies one of those and the code that does it is the only such
# code in the image that has ever been exercised in the field. Same shape,
# same openssl invocation, same failure messages.
#
# The signature is over the base64 manifest *string*, not over the JSON it
# decodes to. That is what parkeze-adopt does, and matching it matters more
# than the aesthetics: signing the decoded form would mean the verifier has to
# reproduce a byte-exact re-encoding before it can check anything, and any
# difference in key order or spacing silently fails verification.
#
# ── WHY THE MANIFEST AND NOT THE IMAGE ─────────────────────────────────────
#
# Ed25519 over 26-40MB would mean the gateway holding the whole image in
# memory to verify it. A RAK has 128MB total and the image is already in tmpfs,
# which is memory. So the signature covers a digest and the gateway checks the
# digest itself — constant memory, and sha256sum streams.

set -euo pipefail

IMAGE="${1:?usage: tools/sign-firmware.sh <image> [board] [version]}"
BOARD="${2:-}"
VERSION="${3:-}"

KEY="${FIRMWARE_SIGNING_KEY_PATH:-${PARKEZE_FIRMWARE_KEY:-}}"

command -v openssl >/dev/null || { echo "openssl is required" >&2; exit 1; }
[ -s "${IMAGE}" ] || { echo "no such image: ${IMAGE}" >&2; exit 1; }

# The key may arrive as a path or, in CI, as the PEM itself in the
# environment. Both, because a secret that has to be written to disk first is
# a secret that gets left on disk.
KEYFILE=""
# `return 0` is load-bearing: this runs from an EXIT trap, and the trap's own
# status becomes the script's. Ending on a false `[ -n "" ] && rm` made every
# successful signing exit 1, which CI would read as a failed release.
cleanup() { [ -n "${KEYFILE}" ] && rm -f "${KEYFILE}"; return 0; }
trap cleanup EXIT

if [ -n "${FIRMWARE_SIGNING_KEY:-}" ]; then
  KEYFILE="$(mktemp)"
  chmod 0600 "${KEYFILE}"
  printf '%s\n' "${FIRMWARE_SIGNING_KEY}" > "${KEYFILE}"
  KEY="${KEYFILE}"
fi

[ -n "${KEY}" ] && [ -s "${KEY}" ] || {
  echo "error: no signing key." >&2
  echo "Set FIRMWARE_SIGNING_KEY (the PEM) or FIRMWARE_SIGNING_KEY_PATH." >&2
  exit 1
}

if command -v sha256sum >/dev/null 2>&1; then
  DIGEST="$(sha256sum "${IMAGE}" | awk '{ print $1 }')"
else
  DIGEST="$(shasum -a 256 "${IMAGE}" | awk '{ print $1 }')"
fi

BUILT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# -A on every base64: openssl wraps at 64 columns by default, and a wrapped
# value inside a JSON string is a different string from the one that was
# signed. parkeze-adopt hit exactly this.
MANIFEST_B64="$(printf '{"sha256":"%s","board":"%s","version":"%s","built":"%s"}' \
                  "${DIGEST}" "${BOARD}" "${VERSION}" "${BUILT}" \
                | openssl base64 -A)"

# Through a file, not a pipe. Ed25519 signing is a one-shot operation: openssl
# needs the whole input size before it starts, and a pipe cannot tell it one —
# it fails with "unable to determine file size for oneshot operation". The
# verifier on the gateway writes the body to a file for the same reason, which
# is where this should have been copied from in the first place.
SIGN_BODY="$(mktemp)"
printf '%s' "${MANIFEST_B64}" > "${SIGN_BODY}"
SIGNATURE="$(openssl pkeyutl -sign -inkey "${KEY}" -rawin -in "${SIGN_BODY}" \
             | openssl base64 -A)"
rm -f "${SIGN_BODY}"

OUT="${IMAGE}.parkeze.json"
printf '{"manifest":"%s","signature":"%s"}\n' "${MANIFEST_B64}" "${SIGNATURE}" > "${OUT}"

# Verified here, against the public half, before anyone relies on it. A
# manifest that does not verify on the machine that just made it will not
# verify on a gateway either, and this is a much better place to find out.
PUB="$(mktemp)"
openssl pkey -in "${KEY}" -pubout -out "${PUB}" 2>/dev/null
SIG_TMP="$(mktemp)"; BODY_TMP="$(mktemp)"
printf '%s' "${SIGNATURE}" | openssl base64 -d -A > "${SIG_TMP}"
printf '%s' "${MANIFEST_B64}" > "${BODY_TMP}"
if ! openssl pkeyutl -verify -pubin -inkey "${PUB}" -rawin \
       -in "${BODY_TMP}" -sigfile "${SIG_TMP}" >/dev/null 2>&1; then
  rm -f "${PUB}" "${SIG_TMP}" "${BODY_TMP}" "${OUT}"
  echo "error: the signature this just produced does not verify." >&2
  exit 1
fi
rm -f "${PUB}" "${SIG_TMP}" "${BODY_TMP}"

echo "Signed ${IMAGE}"
echo "  sha256   ${DIGEST}"
echo "  manifest ${OUT}"
