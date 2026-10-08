#!/usr/bin/env bash
# Installs upstream foundry's cast and anvil for CI (linux amd64) from the
# release tarball pinned by sha256 in config.json, and puts them on the PATH of
# the following steps. No third-party action is involved, and a replaced
# release asset fails the checksum.
#
#   install-foundry.sh <install dir>

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

[ "$#" -eq 1 ] || die "usage: install-foundry.sh <install dir>"
dir="$1"
[ "$(uname -s)-$(uname -m)" = Linux-x86_64 ] || die "install-foundry.sh is for linux amd64 CI runners; install foundry $(cfg .foundry.version) yourself elsewhere"
require_cmd curl tar jq

url="$(cfg .foundry.linuxAmd64Url)"
sha="$(cfg .foundry.linuxAmd64Sha256)"
mkdir -p "$dir"
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --retry 3 -o "$dir/foundry.tar.gz" "$url"
printf '%s  %s\n' "$sha" "$dir/foundry.tar.gz" | sha256sum --check --strict --quiet ||
  die "foundry tarball does not match the pinned sha256"
tar -xzf "$dir/foundry.tar.gz" -C "$dir" cast anvil
rm -f "$dir/foundry.tar.gz"
if [ -n "${GITHUB_PATH:-}" ]; then printf '%s\n' "$dir" >>"$GITHUB_PATH"; fi
"$dir/cast" --version | head -n 1
