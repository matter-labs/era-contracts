---
name: emergency-upgrade
description: Use when emitting and executing a zk-governance EmergencyUpgradeBoard upgrade on the v31 STAGE testnet (e.g. the ZKsync OS CTM asset-tracker patch, or any one-off ProxyAdmin.upgrade / CTM call) — the approveHash + executeEmergencyUpgrade ceremony. Covers building the Call[] proposal, computing the proposal id + the three EIP-712 board digests + per-member Safe message hashes, emitting the approveHash txs and the final executeEmergencyUpgrade calldata, and broadcasting from MetaMask. Stage-specific (1-of-1 Safes, no off-chain signing); read the mainnet caveat before reusing.
---

# Emergency upgrade via the EmergencyUpgradeBoard (v31 stage)

An emergency upgrade routes an arbitrary `Call[]` through the zk-governance
`EmergencyUpgradeBoard` → `ProtocolUpgradeHandler.executeEmergencyUpgrade`,
bypassing the normal schedule/delay flow and clearing any freeze. The board
verifies three ERC-1271 signature bundles (Guardians, Security Council, ZK
Foundation) over the EIP-712 digest of the proposal `id`, then executes the
calls with `msg.sender = ProtocolUpgradeHandler`.

Use this skill to turn a set of governance calls (e.g. the asset-tracker patch's
`setChainCreationParams` + `setUpgradeDiamondCut`) into the exact list of
transactions to broadcast.

## Stage governance addresses (Sepolia)

| Role | Address |
| --- | --- |
| ProtocolUpgradeHandler (PUH) | `0x8f08627524aeD610192132A425D6b9C32a1727EF` |
| EmergencyUpgradeBoard | `0x24de9c60f6E7226F996D4837Feb9337C207B07e6` |
| SecurityCouncil (Multisig, threshold **6**, 8 members) | `0x1D3D9afB89b51b3f0b4958cA55729c83247C57dB` |
| Guardians (Multisig, threshold **5**, 8 members) | `0x6C9499D438cB708457235450aa7dff858cA1585c` |
| ZK Foundation Safe (threshold **1**) | `0x684a96d0123FAda56344DF3208781999Fa768dE1` |

Resolve them live instead of trusting this table: `PUH.emergencyUpgradeBoard()`,
then `board.SECURITY_COUNCIL()/GUARDIANS()/ZK_FOUNDATION_SAFE()`.

## The key stage-only insight: no off-chain signing

**On stage, every Security Council member, every Guardian member, AND the ZK
Foundation are 1-of-1 Gnosis Safes — all owned by the same EOA
`0xd669494442609879b209CcA8eba2BdC904D2E69D`.** (Verify: `cast call <member>
'getOwners()(address[])'` → that one EOA; `getThreshold()` → 1.)

So you never produce ECDSA signatures. Instead the single owner EOA:

1. calls `approveHash(safeMsgHash)` **on each member Safe** (and the ZK Foundation
   Safe) — one tx per Safe, pre-approving the exact message hash the board's
   `checkSignatures` will compute, and
2. the board call carries Gnosis **"approved-hash" markers** (`r = owner`,
   `s = 0`, `v = 1`, 65 bytes, no signature) for each approver.

`Multisig.checkSignatures` then calls `member.isValidSignature(boardDigest, marker)`;
the member Safe recomputes `safeMsgHash = getMessageHash(abi.encode(boardDigest))`
and accepts because `approvedHashes[owner][safeMsgHash] == 1`.

> ⚠️ **Mainnet caveat.** This approveHash-marker trick only works because stage
> members are 1-of-1 Safes sharing one owner. On mainnet the members are
> independent signers/Safes you do **not** all control — you must collect real
> per-member signatures (each member signs the board's EIP-712 digest, or
> approves its own Safe hash) and the threshold parties are distinct people.
> The `_emitForCalls` flow still computes the right digests, but the marker
> shortcut and "one owner sends everything" assumption do not hold.

## The flow (what the board checks)

```
proposal = UpgradeProposal{ calls, executor = board, salt }   // struct order: calls, executor, salt
id       = keccak256(abi.encode(proposal))
dom      = EIP-712 domain("EmergencyUpgradeBoard","1", chainId, board)
digest_R = keccak256(0x1901 ‖ dom ‖ keccak256(abi.encode(TYPEHASH_R, id)))   // R ∈ {Guardians, SC, ZKFoundation}
```

Typehashes (in `deploy-scripts/utils/Utils.sol`):
`ExecuteEmergencyUpgradeGuardians(bytes32 id)`,
`ExecuteEmergencyUpgradeSecurityCouncil(bytes32 id)`,
`ExecuteEmergencyUpgradeZKFoundation(bytes32 id)`.

Each member Safe approves `safeMsgHash = member.getMessageHash(abi.encode(digest_R))`
(the Safe wraps `digest_R` in its own `SafeMessage(bytes message)` EIP-712).

`executeEmergencyUpgrade(calls, salt, guardiansSig, scSig, zkSig)` where
`guardiansSig = abi.encode(address[] members, bytes[] markers)` (members **ascending**,
≥ threshold) — same for `scSig`; `zkSig` is the single ZK-Foundation marker.

## The script (reuse this — do not hand-roll EIP-712 in TS)

`l1-contracts/deploy-scripts/upgrade/EmergencyStageUpgradeCalldata.s.sol`
emits the whole ceremony read-only (no key, no broadcast). It reads members,
thresholds and Safe message hashes from Sepolia and prints:

- **STEP 1:** one `approveHash(...)` tx (`To` + `Data`, selector `0xd4d9bdcd`)
  per approver — the first `threshold` members of each Multisig (ascending) plus
  the ZK Foundation Safe. Send each from the owner EOA.
- **STEP 2:** one `executeEmergencyUpgrade(...)` tx (`To` = board, `Data`,
  selector `0xc03fd44b`) — send last, from any funded account (the board
  verifies the signatures, not the sender).

Runners:

| Function | Calls source |
| --- | --- |
| `runStage0/1/2()` | `.governance_calls.stageN_calls` in `output/stage/ecosystem.toml` (the staged v31 PUH ceremony) |
| `runAssetTrackerPatch()` | `.zksync_os.governance_calls` in `output/stage/zkos-asset-tracker-patch.toml` (the 2 CTM calls) |
| `_emitForCalls(calls, title)` | shared internal — add a thin runner for any new one-off (e.g. a single `ProxyAdmin.upgrade`) |

### Run it

```bash
cd l1-contracts
set -a; source ../.env; set +a   # needs L1_RPC_URL (Sepolia)
forge script deploy-scripts/upgrade/EmergencyStageUpgradeCalldata.s.sol:EmergencyStageUpgradeCalldata \
  --sig 'runAssetTrackerPatch()' --rpc-url "$L1_RPC_URL"
```

### Add a runner for a new emergency upgrade

```solidity
function runMyUpgrade() external view {
    IProtocolUpgradeHandler.Call[] memory calls = new IProtocolUpgradeHandler.Call[](1);
    calls[0] = IProtocolUpgradeHandler.Call({ target: TARGET, value: 0, data: abi.encodeCall(...) });
    _emitForCalls(calls, "MY UPGRADE");
}
```

For calls already abi-encoded as a `Call[]` blob in a TOML, mirror
`runAssetTrackerPatch()`: `vm.readFile(PATH).readBytes(".<table>.<key>")` then
`abi.decode(_, (IProtocolUpgradeHandler.Call[]))`.

## Verify before broadcasting

Decode the STEP-2 calldata and assert it matches the reviewed calls:

```js
const iface = new ethers.utils.Interface([
  "function executeEmergencyUpgrade((address,uint256,bytes)[] calls,bytes32 salt,bytes g,bytes sc,bytes zk)"]);
const d = iface.decodeFunctionData("executeEmergencyUpgrade", execData);
// selector 0xc03fd44b; salt 0x0; calls match the verified governance calls;
const [gm] = ethers.utils.defaultAbiCoder.decode(["address[]","bytes[]"], d.g);  // length == 5, ascending
const [sm] = ethers.utils.defaultAbiCoder.decode(["address[]","bytes[]"], d.sc); // length == 6, ascending
// d.zk is one 65-byte marker
```

For the asset-tracker patch, `d.calls[0].data` / `d.calls[1].data` must be
byte-identical to the patch's verified `set_chain_creation_params_calldata` /
`set_upgrade_diamond_cut_calldata` (see the `v31-calldata-review` /
`patch-zkos-ctm-asset-tracker.ts` skill — run that first to prove the calls).

## Broadcasting (you / MetaMask)

1. Send the 12 (5 Guardians + 6 SC + 1 ZK Foundation) `approveHash` txs from the
   owner EOA `0xd669…E69D` (value 0).
2. Send the `executeEmergencyUpgrade` tx last (board `0x24de…07e6`, value 0).
3. Confirm: `EmergencyUpgradeExecuted(id)` emitted; the target effects landed
   (e.g. CTM `NewChainCreationParams` / `NewUpgradeCutData` for the patch).

A convenience packer wrote `emergency-upgrade-asset-tracker-txs.json` (all 13
txs as `{to,value,data}`) — regenerate it from the script output for a new run.

## Gotchas

- **`id` includes the salt** (`bytes32(0)` in the script). The handler reverts
  `"Upgrade already exists"` if a proposal with the same `(calls, executor=board,
  salt)` was already executed. To re-run intentionally-different calls reusing
  the same targets, bump the salt.
- **Member order is load-bearing.** `checkSignatures` walks `members` in storage
  order and requires the supplied signers strictly ascending — the script uses
  the first `threshold` members, which are already ascending.
- **Marker format:** `abi.encodePacked(bytes32(uint160(owner)), bytes32(0),
  uint8(1))`. Wrong `owner`, or a member whose Safe owner ≠ that EOA, fails
  ERC-1271.
- **Emergency upgrade clears the freeze** and needs no delay — that's the whole
  point of the emergency path vs `startUpgrade`/`execute`.
- **Prereq for the patch:** the new bytecodes must already be published to the
  `BytecodesSupplier` (`publishEVMBytecodes`) before execute, or the CTM calls
  revert on unknown bytecode hashes.
- **Genesis-root provenance:** for the asset-tracker patch, the `genesisBatchHash`
  in call0 comes from a regenerated genesis. Reproduce it on the canonical Linux
  build / PUVT-check it before executing on chain — local macOS artifacts are
  deterministic for EVM bytecode but the genesis value should be confirmed on the
  canonical toolchain.

## Related

- `v31-calldata-review` / `PatchZkosCtmAssetTracker.md` — generate + verify the
  CTM calls this upgrade executes.
- `regenerate-v31-stage-calldata` — produces the `ecosystem.toml` stage calls
  that `runStage0/1/2()` consume.
- zk-governance sources: `EmergencyUpgradeBoard.sol`, `Multisig.sol`,
  `ProtocolUpgradeHandler.sol`, `interfaces/IProtocolUpgradeHandler.sol`.
