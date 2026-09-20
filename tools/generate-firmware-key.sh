#!/usr/bin/env bash
#
# Generate the firmware signing keypair.
#
#   tools/generate-firmware-key.sh [output-dir]
#
# WHAT THIS KEY IS
#
# One Ed25519 keypair that answers a single question: did Parkeze build this
# image? The *public* half is baked into every image at build time, at
# /etc/parkeze/firmware.pub. The *private* half signs a small manifest beside
# each released image — see tools/sign-firmware.sh.
#
# WHY IT IS NOT THE FLEET RECOVERY KEY
#
# It would be easy to reuse recovery_ed25519, which gateways already carry.
# Deliberately not doing that, because the two keys live in different places
# and are exposed to different things. The recovery key's private half never
# leaves recovery-service; this one has to be reachable by CI, which builds
# the images. Signing firmware with the recovery key would drag a key whose
# whole value is that it sits in one service into a build runner, and a
# compromise there would then also be a compromise of offline adoption and
# console recovery for the entire fleet. Two keys means a stolen CI secret
# forges firmware and nothing else.
#
# WHAT A STOLEN PRIVATE HALF COSTS
#
# Someone who has it can produce an image a gateway will accept. They still
# need a way to deliver it — a console session, or SSH — so it is not on its
# own a route in. But it removes the last check that would have caught a
# tampered image once they have one, so treat it as fleet-wide.
#
# ROTATION
#
# Rotating is a firmware upgrade, not a visit: the new public key ships in the
# image. So roll out an image signed with the OLD key that CARRIES the new
# public key, let the fleet take it, and only then start signing with the new
# one. Reversing those two steps leaves every gateway refusing the images that
# would have fixed them.

set -euo pipefail

OUT_DIR="${1:-.}"
PRIVATE="${OUT_DIR}/firmware_ed25519"
PUBLIC="${OUT_DIR}/firmware_ed25519.pub"

command -v openssl >/dev/null || { echo "openssl is required" >&2; exit 1; }

if [ -e "${PRIVATE}" ]; then
  echo "error: ${PRIVATE} already exists." >&2
  echo "Refusing to overwrite a firmware signing key. If this is the live one," >&2
  echo "replacing it means every gateway rejects every image you sign next." >&2
  exit 1
fi

umask 077
openssl genpkey -algorithm ed25519 -out "${PRIVATE}"
openssl pkey -in "${PRIVATE}" -pubout -out "${PUBLIC}"
chmod 0600 "${PRIVATE}"
chmod 0644 "${PUBLIC}"

cat <<EOF

Firmware signing keypair written.

  private  ${PRIVATE}    ← CI secret only. Do not commit.
  public   ${PUBLIC}     ← baked into every image.

Next:

  1. Add the private key to the repository's Actions secrets as
     FIRMWARE_SIGNING_KEY (the whole PEM, including the BEGIN/END lines).

  2. Commit the public half, or point the build at it:

       PARKEZE_FIRMWARE_PUBKEY=/absolute/path/to/firmware_ed25519.pub ./build.sh

  3. Verify it round-trips before you rely on it:

       printf 'test' > /tmp/m
       openssl pkeyutl -sign -inkey ${PRIVATE} -rawin -in /tmp/m -out /tmp/s
       openssl pkeyutl -verify -pubin -inkey ${PUBLIC} -rawin -in /tmp/m -sigfile /tmp/s

     That is the same verify a gateway runs against a manifest. If it does not
     print "Signature Verified Successfully", stop and fix it here — the
     alternative is a fleet that refuses every image you ship.

  4. Delete your local copy of the private key once it is in Actions secrets.

EOF
