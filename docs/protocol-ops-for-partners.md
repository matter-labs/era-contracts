# protocol-ops for partners

For teams that run their own ecosystem or chain on these contracts (ADI, for example). The calldata
for a chain operation needs docker and an RPC for your L1, no checkout and no toolchain.

## The image

We send you a digest, `ghcr.io/matter-labs/protocol-ops@sha256:<digest>` (public, `linux/amd64`),
once we have run it on our own `stage`. Use the digest, not a tag. The image holds the contracts at
its release commit, built, with `protocol_ops`, forge, cast and the configs under
`l1-contracts/upgrade-envs/`, your preset (`permanent-values/adi.toml`) included. To change a
config, tell us: it ships in a new image. `docker inspect --format '{{json .Config.Labels}}'` shows:

- `org.opencontainers.image.revision`: the era-contracts commit it was built from. An image without
  it was not released by `build-docker`, so don't use it (images before v0.35.0 have none: ask us).
- `io.matter-labs.protocol-ops.tested-with`: the zksync-os-integration-tests run that passed with
  that commit (`build-docker` checks it before pushing).
- `io.matter-labs.protocol-ops.zk-governance-commit`: the zk-governance commit it holds for a
  governance redeploy.

## A chain operation

```bash
IMAGE=ghcr.io/matter-labs/protocol-ops@sha256:<digest>
mkdir -p out
docker run --rm --platform linux/amd64 -v "$PWD/out:/out" "$IMAGE" \
  protocol_ops chain set-upgrade-timestamp --env adi --chain-id 36900 \
  --l1-rpc-url <l1-rpc> --upgrade-timestamp <unix-seconds> --out /out
```

`chain upgrade`, `chain add-validator` and `chain remove-validator` run the same way (`--help` lists
their flags). Use an empty `out/` for each: it gets the Safe bundles (`*.safe.json`), `manifest.json`
and `EXECUTE.md`.

## Keys

The commands prepare calldata on an anvil fork of your L1: nothing is signed or sent. You send the
result from your own accounts (your ChainAdmin's owner, your deployer, your Governance's owner). We
never need your keys and you never need ours.
