# L1ChainAssetHandler owner fix (ZKsync Sepolia)

Tooling to repair a misconfigured **L1ChainAssetHandler** `TransparentUpgradeableProxy` on
**Ethereum Sepolia** whose `owner()` is `address(0)` and set it to the correct owner via a single,
atomic Governance operation.

## The problem

The contract to fix is the chain asset handler. It is found by querying the Bridgehub:

```bash
cast call 0xc4fd2580c3487bba18d63f50301020132342fdbd "chainAssetHandler()(address)" --rpc-url $SEPOLIA_RPC
# -> 0xDfA2193b161d7bd45FC81b4E80225eebDc3CF96C
cast call 0xDfA2193b161d7bd45FC81b4E80225eebDc3CF96C "owner()(address)"            --rpc-url $SEPOLIA_RPC
# -> 0x0000000000000000000000000000000000000000   (the misconfiguration)
```

| role | address |
| --- | --- |
| Bridgehub (used to locate the CAH) | [`0xc4fd2580c3487bBA18d63f50301020132342fDBD`](https://sepolia.etherscan.io/address/0xc4fd2580c3487bba18d63f50301020132342fdbd) |
| **L1ChainAssetHandler proxy (broken, `owner()==0`)** | [`0xDfA2193b161d7bd45FC81b4E80225eebDc3CF96C`](https://sepolia.etherscan.io/address/0xDfA2193b161d7bd45FC81b4E80225eebDc3CF96C) |
| Original implementation (`L1ChainAssetHandler`) | [`0xC32FCA197a5E2F29CC7A072F38ebde31F1E9354F`](https://sepolia.etherscan.io/address/0xC32FCA197a5E2F29CC7A072F38ebde31F1E9354F#code) |
| ProxyAdmin (admin of the proxy) | `0xE00456791Da489418355B0a6b27965A54c7C01d2` |
| Governance (owner of the ProxyAdmin) | `0xcf96aAb01347BA96050F39Ff6dcbC6138b462b58` |
| Governance owner — the EOA that signs | `0x5555555590930f501c88B73Ea43B3EEb5A71643c` |
| **New, correct owner to set** | `0x803e5E7aF1FDD504F8844E28a249203Cfa7c471D` |

The `initialize(address)` call that should have set the owner was never executed, so `owner()`
returns `address(0)`. `Ownable2StepUpgradeable` cannot recover from a zero owner through its normal
API, so the owner must be written directly.

## Storage-layout analysis (the "double check")

The deployed implementation is verified on Etherscan as **`L1ChainAssetHandler`** (solc 0.8.28).
Its on-chain getters read the OpenZeppelin base slots at exactly the positions `main`'s
`ChainAssetHandler` predicts (verified by disassembly of the deployed runtime and by
`forge inspect contracts/bridgehub/ChainAssetHandler.sol:ChainAssetHandler storage-layout`):

| variable | slot |
| --- | --- |
| `_owner` (OZ `OwnableUpgradeable`) | **51** |
| `_pendingOwner` (OZ `Ownable2StepUpgradeable`) | **101** |
| `_paused` (OZ `PausableUpgradeable`) | **151** |
| `migrationPaused` | **201** |

The deployed `L1ChainAssetHandler` and `main`'s `ChainAssetHandler` have **byte-different but
storage-layout-identical** implementations: the storage layouts match for every slot, so the
upgrade is safe.

## The temporary implementation

[`contracts/dev-contracts/ChainAssetHandlerOwnerForceUpdate.sol`](../../../contracts/dev-contracts/ChainAssetHandlerOwnerForceUpdate.sol)
is `main`'s `ChainAssetHandler` with a single added function:

```solidity
function forceSetOwner(address addr) external {
    _transferOwnership(addr);
}
```

Because it `is ChainAssetHandler` and adds no storage variables, its storage layout is identical
to `ChainAssetHandler` (verified with `forge inspect ... storage-layout`: `_owner` at slot 51).

**Deployed & verified temporary implementation (Sepolia):**
[`0x23a460AaFfB492781aE2D61c1c331A61C055e9Cf`](https://sepolia.etherscan.io/address/0x23a460AaFfB492781aE2D61c1c331A61C055e9Cf#code)

Constructor args used (immutables; irrelevant to `forceSetOwner`; identical to the deployed
original implementation):
`_l1ChainId = 11155111`, `_owner = 0x5555555590930f501c88B73Ea43B3EEb5A71643c`,
`_bridgehub = 0xc4fd2580c3487bBA18d63f50301020132342fDBD`,
`_assetRouter = 0xB5d9c3f41e434b91295bd7962db5C873CeCce2be`,
`_messageRoot = 0xE7047cD9979D053CeB6db637bc0383b87a3C7f58`.

## The fix — one atomic Governance operation

The Governance operation (a multicall) contains two calls on the `ProxyAdmin`:

1. `upgradeAndCall(proxy, tempImpl, forceSetOwner(newOwner))` — install the temp impl and, in the
   same call, write the owner.
2. `upgrade(proxy, originalImpl)` — restore the original implementation.

Since they are in one operation they execute atomically. The Governance `minDelay` is `0`, so the
EOA owner submits two transactions:

1. `scheduleTransparent(operation, 0)`
2. `execute(operation)`

The ready-to-send transactions are in [`calldata.json`](./calldata.json), in the required format
(`description / network / from / to / data / value / valueToMint`).

## Reproduce

All commands run from `l1-contracts/`.

### 1. Deploy & verify the temporary implementation

```bash
RPC_URL=$SEPOLIA_RPC \
PRIVATE_KEY=$DEPLOYER_PK \
ETHERSCAN_API_KEY=$ETHERSCAN_API_KEY \
./deploy-scripts/dev/chain-asset-handler-owner-fix/deploy-and-verify.sh
```

The script is restartable: it records the deployed address in `deployment.env` and will only
(re)verify on re-run.

### 2. Generate the governance calldata

```bash
# TEMP_IMPL defaults to the already-deployed address above; override to use your own.
TEMP_IMPL=0x23a460AaFfB492781aE2D61c1c331A61C055e9Cf \
forge script deploy-scripts/dev/GenerateChainAssetHandlerOwnerFixCalldata.s.sol:GenerateChainAssetHandlerOwnerFixCalldata
# -> writes script-out/chain-asset-handler-owner-fix-calldata.json
```

Every address and the salt can be overridden via env vars
(`CHAIN_ASSET_HANDLER_PROXY`, `PROXY_ADMIN`, `GOVERNANCE`, `GOVERNANCE_OWNER`, `ORIGINAL_IMPL`,
`TEMP_IMPL`, `NEW_OWNER`, `SALT`, `NETWORK`).

### 3. Simulate the fix on a fork (and assert the outcome)

Run the bundled script — it forks the given RPC, sends the two transactions from `calldata.json`
(impersonating the Governance owner via anvil "unlocked" accounts), and asserts that afterwards the
implementation is restored to the original impl and `owner()` returns the intended new owner:

```bash
RPC_URL=$SEPOLIA_RPC ./deploy-scripts/dev/chain-asset-handler-owner-fix/simulate-on-fork.sh
```

Expected output:

```
owner() after:        0x803e5E7aF1FDD504F8844E28a249203Cfa7c471D  (expected 0x803e5E7aF1FDD504F8844E28a249203Cfa7c471D)
implementation after: 0xc32fca197a5e2f29cc7a072f38ebde31f1e9354f  (expected 0xC32FCA197a5E2F29CC7A072F38ebde31F1E9354F)
PASS: owner() is the intended new owner
PASS: implementation restored to the original impl
PASS: proxy is functional on the restored implementation (migrationPaused() callable)

ALL CHECKS PASSED ✅
```

The script exits non-zero if any assertion fails. All targets (proxy, governance, expected impl,
new owner) can be overridden via env vars — see the header of `simulate-on-fork.sh`.
