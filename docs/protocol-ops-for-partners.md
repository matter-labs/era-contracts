# protocol-ops for partners

For teams that run their own ecosystem or chain on these contracts (ADI, for example) and need the
calldata for a chain operation or an ecosystem upgrade. A chain operation needs docker and an RPC for
your L1, no checkout and no toolchain.

## What we give you

A released image, `ghcr.io/matter-labs/protocol-ops@sha256:<digest>` (public, `linux/amd64`). It
holds the contracts at the release commit, their compiled artifacts, `protocol_ops`, forge, cast and
anvil, and the configs under `l1-contracts/upgrade-envs/`, your ecosystem's preset
(`permanent-values/<env>.toml`, `adi` for ADI) included.

We send the digest, from the run summary of the `build-docker` run that released it. Use the digest,
not a tag: a tag can be moved.

```bash
IMAGE=ghcr.io/matter-labs/protocol-ops@sha256:<digest>
docker pull --platform linux/amd64 "$IMAGE"
docker inspect --format '{{json .Config.Labels}}' "$IMAGE"
```

| Label                                     | Meaning                                                                   |
| ----------------------------------------- | ------------------------------------------------------------------------- |
| `org.opencontainers.image.revision`       | the era-contracts commit the image was built from                         |
| `io.matter-labs.protocol-ops.tested-with` | the zksync-os-integration-tests run the releaser recorded for that commit |
| `org.opencontainers.image.version`        | the tag it was released under                                             |

An image without a `revision` label was not released by `build-docker`: don't use it.

## Keys

The chain commands and `rehearse-upgrade` prepare calldata on an anvil fork of your L1 inside the
container: nothing is signed and nothing is sent. You sign and send the result from your own accounts:

- chain operations: the Safe bundles, from your ChainAdmin's owner or the AccessControlRestriction
  admin;
- ecosystem upgrade deployments: `replay-bundle --key`, with your deployer's key, on your machine;
- ecosystem upgrade governance calls: from your Governance's owner.

We never need your keys and you never need ours.

## Chain operations

```bash
mkdir -p out
docker run --rm --platform linux/amd64 -v "$PWD/out:/out" "$IMAGE" \
  protocol_ops chain set-upgrade-timestamp --env adi --chain-id 36900 \
  --l1-rpc-url <l1-rpc> --upgrade-timestamp <unix-seconds> --out /out
```

`--env adi` takes your bridgehub from the image's `permanent-values/adi.toml`; the chain's admin and
its owner are read from L1.

| Command                                         | Its own flags                                                                    |
| ----------------------------------------------- | -------------------------------------------------------------------------------- |
| `chain set-upgrade-timestamp`                   | `--upgrade-timestamp <unix seconds>`                                             |
| `chain upgrade`                                 | none for a plain upgrade; `--da-mode` and friends when the upgrade moves your DA |
| `chain add-validator`, `chain remove-validator` | `--validator-address <address>`                                                  |

Each also takes `--access-control-restriction <address>` when your ChainAdmin uses an
AccessControlRestriction; the default, the zero address, is for an Ownable ChainAdmin.
`docker run --rm --platform linux/amd64 "$IMAGE" protocol_ops chain <command> --help` lists the rest.
`chain upgrade` takes the upgrade from your CTM on L1, so run it once your ecosystem has the new
version. The commands are tested against chains on the image's release: for a chain on an older
version, ask us which image to use.

Use an empty `out/` for each command: `manifest.json` is appended to, and `EXECUTE.md` lists every
bundle in it. `out/` then holds:

- `*.safe.json`: the bundles, one per run of consecutive calls from the same signer. Import them in
  your Safe's Transaction Builder, or send them from the owner EOA;
- `manifest.json`: the bundles in execution order, each with its `target` (the account that sends it)
  and the inputs that produced it;
- `EXECUTE.md`: the same transactions (`to`, `value`, `data`), to send by hand.

On Linux the files belong to root, the container's user. We can also run the chain workflows with
`environment: adi`: they upload the same files as an artifact.

## Ecosystem upgrades

An upgrade of your ecosystem needs your release inputs in the image,
`upgrade-envs/<release>/<env>.toml`, next to your preset: owners and CREATE2 salts. We commit them and
release an image. The current release, `v0.35.0-upgrade-system`, has no `adi.toml` yet.

These steps write a bundle you keep, so run them with `./protocol-ops.sh --tag sha256:<digest>` from a
checkout of the image's `revision`, so the outputs land in it.

1. Generate with your deployer's address, or have us run `generate-ecosystem-upgrade-calldata` with it
   as `deployer_address` and send you the deploy bundle. The address is baked into the init code of
   some deployments, so the EOA that broadcasts must be this one.

   ```bash
   ./protocol-ops.sh --tag sha256:<digest> ecosystem rehearse-upgrade --env <env> \
     --fork-url <l1-rpc> --deployer-address <your deployer>
   ```

2. Broadcast the deployer's bundles with your key. `replay-bundle` refuses a key for any other account
   and sends only the deployer's bundles.

   ```bash
   EXTRA_MOUNTS="$PWD/<unpacked-bundle-dir>:/contracts/bundle" \
     ./protocol-ops.sh --tag sha256:<digest> ecosystem replay-bundle \
     --bundle /contracts/bundle --rpc <l1-rpc> --key "$DEPLOYER_KEY"
   ```

3. Verify the deployment before governance signs: the same command with `--verify-only` in place
   of `--key`.

4. Send the governance bundle, `[governance_calls] calls` in the bundle's `ecosystem.toml`, through
   your Governance from its owner: schedule it with at least your `minDelay` (three days for ADI),
   then execute it once the delay has passed, or have your security council execute it instantly.
   Steps 1 to 3 don't run these calls, so the delay doesn't affect them.
   `ecosystem upgrade-governance` writes the calls as a Safe bundle that schedules with no delay,
   which a Governance with a `minDelay` refuses (`InvalidDelay`), on a fork too.

How to rehearse the broadcast on a fork first and verify it afterwards:
[Deploying + verifying from a deploy bundle](ecosystem-upgrade-deploy.md#deploying--verifying-from-a-deploy-bundle).

## Changing a config

The configs are part of the image. Tell us what to change: we merge it and release a new image, with a
new digest.
