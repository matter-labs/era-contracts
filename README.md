# Atomic interop demo assets

This branch is not part of the era-contracts history. It holds a large generated file for the atomic
interop demo in `docs/atomic-interop/docs-atomic-interop-demo/` on `main`, so that `main` doesn't carry it.

- `l1-state.json.gz`: the demo's L1 (Anvil) state with two ZKsync OS v33 chains, 506 and 507. It is made
  by `docker/generate-l1-state.sh` in the demo folder; the demo's README explains how.

The demo downloads the file from a fixed commit of this branch and checks its sha256, so don't delete
this branch or rewrite its history. To publish a new state, add a commit here and update the commit and
hash in the demo's `docker/fetch-l1-state.mjs`.
