#!/usr/bin/env bash
#
# Pre-installs every zksolc version pinned by the repository's foundry.toml files
# into the directory foundry-zksync resolves compilers from (~/.zksync).
#
# foundry-zksync downloads stable zksolc releases from the matter-labs/zksolc-bin
# mirror, which stopped publishing after v1.5.15. Fetching the binaries from the
# canonical matter-labs/era-compiler-solidity releases up front keeps
# `forge build --zksync` working for versions the mirror never received.
#
# Run from the repository root.

set -euo pipefail

case "$(uname -s)" in
  Linux) prefix="zksolc-linux-amd64-musl-v" ;;
  Darwin) prefix="zksolc-macosx-amd64-v" ;;
  *) echo "unsupported OS $(uname -s)" >&2 && exit 1 ;;
esac

# Every package lives one level below the repository root, so a glob is enough and
# this stays portable to the slim images used for the docker builds.
versions=$(sed -n 's/^[[:space:]]*zksolc[[:space:]]*=[[:space:]]*"\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)".*/\1/p' \
    ./*/foundry.toml | sort -u)

if [ -z "$versions" ]; then
  echo "no zksolc version pinned in any foundry.toml" >&2
  exit 1
fi

mkdir -p "$HOME/.zksync"
for version in $versions; do
  binary="$HOME/.zksync/${prefix}${version}"
  if [ -x "$binary" ]; then
    echo "zksolc $version already installed"
    continue
  fi
  echo "Installing zksolc $version"
  curl -sSfL -o "$binary" \
    "https://github.com/matter-labs/era-compiler-solidity/releases/download/${version}/${prefix}${version}"
  chmod +x "$binary"
done
