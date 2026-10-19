#!/usr/bin/env bash
# Installs the anvil pinned in .github/amsterdam-anvil.env into <dest-dir> and prints its path.
# Only anvil is extracted and foundryup is never run, so the Foundry toolchain on PATH stays untouched.
#
# Usage: install-amsterdam-anvil.sh <dest-dir>
set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "usage: $0 <dest-dir>" >&2
  exit 2
fi
dest="$1"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
# shellcheck source=.github/amsterdam-anvil.env
. "$repo_root/.github/amsterdam-anvil.env"

platform="$(uname -s)/$(uname -m)"
case "$platform" in
  Linux/x86_64)
    asset="$AMSTERDAM_ANVIL_ASSET_LINUX_AMD64"
    expected_sha256="$AMSTERDAM_ANVIL_SHA256_LINUX_AMD64"
    ;;
  Darwin/arm64)
    asset="$AMSTERDAM_ANVIL_ASSET_DARWIN_ARM64"
    expected_sha256="$AMSTERDAM_ANVIL_SHA256_DARWIN_ARM64"
    ;;
  *)
    echo "install-amsterdam-anvil: no pinned asset for $platform (pinned: Linux/x86_64, Darwin/arm64)" >&2
    exit 1
    ;;
esac

sha256_of() {
  if command -v sha256sum > /dev/null; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

url="https://github.com/foundry-rs/foundry/releases/download/${AMSTERDAM_ANVIL_TAG}/${asset}"
echo "install-amsterdam-anvil: downloading $url" >&2
curl --fail --location --silent --show-error --retry 3 --output "$work/$asset" "$url"

actual_sha256="$(sha256_of "$work/$asset")"
if [ "$actual_sha256" != "$expected_sha256" ]; then
  echo "install-amsterdam-anvil: sha256 mismatch for $asset: got $actual_sha256, pinned $expected_sha256" >&2
  exit 1
fi

mkdir -p "$work/extract" "$dest"
tar -xzf "$work/$asset" -C "$work/extract" anvil
install -m 0755 "$work/extract/anvil" "$dest/anvil"
echo "$(cd "$dest" && pwd)/anvil"
