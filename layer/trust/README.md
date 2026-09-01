<!-- SPDX-License-Identifier: BUSL-1.1 -->

# layer/trust — install-time trust anchors

The public component of the evo framework's release signing key, used
by both `scripts/install/install.sh` and the runtime verification
primitive at `layer/bin/evo-kiosk-verify`.

## What lives here

- **`evo-release-signing-public.pem`** — Ed25519 public key. The private
  half signs channel pointers and per-target binaries in
  [foonerd/evo-kiosk-artefacts](https://github.com/foonerd/evo-kiosk-artefacts)
  (and every peer release plane). Consumers verify against this file
  before placing a binary from the release plane on a target.

## Install-time placement

`scripts/install/install.sh` copies this file to `/etc/evo/trust/`
with mode 0644 and root ownership. `evo-kiosk-verify` reads it from
that location by default; override via `EVO_KIOSK_TRUST_ANCHOR` when
verifying with an operator-pinned key.

## Chain of custody

The chain from a signed release to a placed binary on-target:

1. The evo framework's private signing key signs channel pointers +
   per-target binaries + per-target build-info manifests during a
   release cut (see the eng-side `scripts/release/publish-artefacts.sh`).
2. The signed set lands in the artefacts repository over an
   authenticated git push to GitHub.
3. On-target install (or verify) fetches the artefacts repo over
   HTTPS/TLS with GitHub's server certificate providing the transport
   trust.
4. The bundled trust anchor here — carried by the install source
   itself — verifies each fetched signature before the binary is
   placed at `/usr/local/bin/evo-kiosk-browser`.

Tampering with the trust anchor requires tampering with the install
source itself. Tampering with an in-flight artefact requires forging
a signature under the release private key. Both attacks fail unless
the attacker holds either write access to this repository or the
release private key.

## Rotation

Rotating the signing key requires:

1. Generating a new keypair on the release-signing machine.
2. Committing the new public key over this file in a signed source
   commit.
3. Re-signing existing channel pointers + binaries under the new key,
   or letting existing content age out on its natural release cadence.
4. Distributing an install source refresh (git pull, distribution
   bundle bump) so consumers pick up the new trust anchor before
   the next fetch.

Consumers that have not refreshed the trust anchor will fail to
verify newly-signed content until they do. This is by design.
