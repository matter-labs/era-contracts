# Bridgehub owner fix (ZKsync Sepolia)

Tooling to repair a misconfigured **Bridgehub** `TransparentUpgradeableProxy` on **Ethereum Sepolia**
whose `owner()` is `address(0)` and set it to the correct owner via a single, atomic Governance
operation.

## The problem

| role | address |
| --- | --- |
| Bridgehub proxy (broken) | [`0xDfA2193b161d7bd45FC81b4E80225eebDc3CF96C`](https://sepolia.etherscan.io/address/0xDfA2193b161d7bd45FC81b4E80225eebDc3CF96C) |
| Original implementation | [`0xC32FCA197a5E2F29CC7A072F38ebde31F1E9354F`](https://sepolia.etherscan.io/address/0xC32FCA197a5E2F29CC7A072F38ebde31F1E9354F) |
| ProxyAdmin (admin of the proxy) | `0xE00456791Da489418355B0a6b27965A54c7C01d2` |
| Governance (owner of the ProxyAdmin) | `0xcf96aAb01347BA96050F39Ff6dcbC6138b462b58` |
| Governance owner — the EOA that signs | `0x5555555590930f501c88B73Ea43B3EEb5A71643c` |
| **New, correct owner to set** | `0x803e5E7aF1FDD504F8844E28a249203Cfa7c471D` |

The proxy's storage is **completely uninitialized** — every slot reads `0x0`, including the
`Initializable._initialized` flag at slot 0. The `initialize(address)` call that should have set
the owner was never executed, so `owner()` returns `address(0)`. `Ownable2StepUpgradeable` cannot
recover from a zero owner through its normal API, so the owner must be written directly.

## Storage-layout analysis (the "double check")

The deployed implementation was disassembled and compared against the `main`-branch `Bridgehub`:

* The on-chain getters read the OpenZeppelin base slots at exactly the positions `main` predicts:
  * `owner()` → slot **51**
  * `pendingOwner()` → slot **101**
  * `paused()` → slot **151**
* These slots (0–200) are fixed by the inherited base contracts
  (`Initializable` + era `ReentrancyGuard` + `Ownable2StepUpgradeable` + `PausableUpgradeable`) and
  are **identical** between the deployed implementation, the temporary implementation, and `main`.

> ⚠️ Note: the deployed implementation is an **older** `Bridgehub` than current `main` — its
> *Bridgehub-specific* storage (slots ≥ 201) differs (e.g. `migrationPaused` is read from slot 201
> on-chain vs slot 219 on `main`). This **does not matter** for this fix because:
> 1. the proxy storage is empty (nothing to corrupt), and
> 2. the temporary implementation is installed only for the duration of the single `forceSetOwner`
>    call and is reverted to the original implementation in the same atomic operation; only the
>    base `_owner` slot (51, identical everywhere) is ever written.

## The temporary implementation

[`contracts/dev-contracts/BridgehubOwnerForceUpdate.sol`](../../../contracts/dev-contracts/BridgehubOwnerForceUpdate.sol)
is `main`'s `Bridgehub` with a single added function:

```solidity
function forceSetOwner(address addr) external {
    _transferOwnership(addr);
}
```

Because it `is Bridgehub` and adds no storage variables, its storage layout is identical to
`Bridgehub` (verified with `forge inspect ... storage-layout`: `_owner` at slot 51).

**Deployed & verified temporary implementation (Sepolia):**
[`0xA28C7C88037e42103e606477d2754A50D87B9E0A`](https://sepolia.etherscan.io/address/0xA28C7C88037e42103e606477d2754A50D87B9E0A#code)

Constructor args used (immutables; irrelevant to `forceSetOwner`):
`_l1ChainId = 11155111`, `_owner = 0x803e5E7aF1FDD504F8844E28a249203Cfa7c471D`, `_maxNumberOfZKChains = 100`.

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
./deploy-scripts/dev/bridgehub-owner-fix/deploy-and-verify.sh
```

The script is restartable: it records the deployed address in `deployment.env` and will only
(re)verify on re-run.

### 2. Generate the governance calldata

```bash
# TEMP_IMPL defaults to the already-deployed address above; override to use your own.
TEMP_IMPL=0xA28C7C88037e42103e606477d2754A50D87B9E0A \
forge script deploy-scripts/dev/GenerateBridgehubOwnerFixCalldata.s.sol:GenerateBridgehubOwnerFixCalldata
# -> writes script-out/bridgehub-owner-fix-calldata.json
```

Every address and the salt can be overridden via env vars
(`BRIDGEHUB_PROXY`, `PROXY_ADMIN`, `GOVERNANCE`, `GOVERNANCE_OWNER`, `ORIGINAL_IMPL`, `TEMP_IMPL`,
`NEW_OWNER`, `SALT`, `NETWORK`).

### 3. (Optional) simulate the fix on a fork

```bash
anvil --fork-url $SEPOLIA_RPC --port 8546 &
GOV=0xcf96aAb01347BA96050F39Ff6dcbC6138b462b58
OWNER=0x5555555590930f501c88B73Ea43B3EEb5A71643c
PROXY=0xDfA2193b161d7bd45FC81b4E80225eebDc3CF96C
cast rpc anvil_setBalance  $OWNER 0xde0b6b3a7640000 --rpc-url http://127.0.0.1:8546
cast rpc anvil_impersonateAccount $OWNER --rpc-url http://127.0.0.1:8546
cast send $GOV "$(jq -r '.[0].data' deploy-scripts/dev/bridgehub-owner-fix/calldata.json)" --from $OWNER --unlocked --rpc-url http://127.0.0.1:8546
cast send $GOV "$(jq -r '.[1].data' deploy-scripts/dev/bridgehub-owner-fix/calldata.json)" --from $OWNER --unlocked --rpc-url http://127.0.0.1:8546
cast call $PROXY 'owner()(address)' --rpc-url http://127.0.0.1:8546
# -> 0x803e5E7aF1FDD504F8844E28a249203Cfa7c471D
```

This exact flow was run against a Sepolia fork: `owner()` went from `0x0` to
`0x803e…471D` and the implementation slot was restored to the original
`0xC32F…9354F`.
