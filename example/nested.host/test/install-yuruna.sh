#!/bin/bash
# Version: 2026.10.31
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# GUID: 429f5023-d920-458f-9bdd-3f244d88f773
# Installs the framework on the nested host through the verified install of
# install/README.md: the installer runs only after the release key matches the
# fingerprint pinned below, the key verifies the manifest signature, and the
# installer's digest equals its own manifest row. A failed download or check
# exits non-zero before anything runs, so the step cannot pass with nothing
# installed.
set -euo pipefail

BASE='https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main'
INSTALLER='install/ubuntu.kvm.sh'
# SHA-256 of the release key's DER encoding, published out of band in
# install/keys/README.md. The key is downloaded with the manifest it verifies,
# so only this pin ties the signature to the release owner.
RELEASE_KEY_SHA256='14fce044df5de1ebbac6fdeae8d4f87abac618393f06e32748b7ef4571c5c337'

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# One cache-buster for every file, so the four downloads describe one commit.
nocache=$(date +%Y%m%d%H%M%S)
for file in "$INSTALLER" install/install.sha256 install/install.sha256.sig install/keys/yuruna-release-signing.pub.pem; do
    curl -fsSL --retry 3 "$BASE/$file?nocache=$nocache" -o "$work/$(basename "$file")" ||
        { echo "DOWNLOAD FAILED: $file -- the installer was not run" >&2; exit 1; }
done

key="$work/yuruna-release-signing.pub.pem"
got_key=$(openssl pkey -pubin -in "$key" -outform DER | openssl dgst -sha256 -r | cut -d' ' -f1) || got_key=''
[ "$got_key" = "$RELEASE_KEY_SHA256" ] ||
    { echo "RELEASE KEY MISMATCH: got '${got_key}' -- the installer was not run" >&2; exit 1; }
openssl dgst -sha256 -verify "$key" -signature "$work/install.sha256.sig" "$work/install.sha256" >/dev/null ||
    { echo 'SIGNATURE INVALID -- the installer was not run' >&2; exit 1; }
got=$(openssl dgst -sha256 -r "$work/$(basename "$INSTALLER")" | cut -d' ' -f1) || got=''
want=$(awk -v p="$INSTALLER" 'NF == 2 && $2 == p { print $1; n++ } END { if (n != 1) exit 1 }' "$work/install.sha256") || want=''
if ! printf '%s\n' "$got" | grep -Eqx '[0-9a-f]{64}' || [ "$got" != "$want" ]; then
    echo 'INSTALLER HASH MISMATCH -- the installer was not run' >&2
    exit 1
fi

# A login shell gives the installer the profile.d environment an operator's
# terminal has. The here-string accepts the intentional 24.04 / eight-core
# requirements warning.
bash -l "$work/$(basename "$INSTALLER")" <<< y
