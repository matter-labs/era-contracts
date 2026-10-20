# Testnet 3 voting deployment preparation

This is the deployment and governance handover record for the EraVM testnet ecosystem on Sepolia and its chain 312. The L2 deployment scripts and L1 upgrade handler live in [zk-governance](https://github.com/zksync-association/zk-governance). Prepare and verify every transaction before broadcasting; this file contains no signing key or transaction.

## Network and current contracts

| Item                         | Address or value                             |
| ---------------------------- | -------------------------------------------- |
| L1 chain ID                  | `11155111` (Sepolia)                         |
| L2 chain ID                  | `312`                                        |
| L2 RPC                       | `https://rpc.zksync-era-testnet.zksync.dev`  |
| Current governance owner EOA | `0xeC6A5c568A59C0858ed6680A6862d64aA2DA8D4b` |
| L1 Governance                | `0xd7b2feb25e924e34bf231efbad04adc4848dc85d` |
| Chain 312 ChainAdmin         | `0xcd759c9bB599e4463771A45F289B318A93Bb07E4` |
| Chain 312 diamond            | `0xbB94d8F4080d5CD34d6215399f26771990f38A1d` |
| EraVM CTM                    | `0x4d058d138f477c4b97b3d762f923811b20220078` |
| Bridgehub                    | `0xf49c690785b9fe5261d786237348a66896e2f477` |
| L1Nullifier                  | `0xd1eae5e399f88751ec2f903785d62cf5a8dc4b9b` |
| L1AssetRouter                | `0x2b64aa3d5aeca9ac4bbf04a48d671da7d6909c03` |
| L1NativeTokenVault           | `0x54edd93d08f703b788587c78b62b64663af14af7` |
| ChainAssetHandler            | `0xcbb88e836507464a4574dbee25bcac91582466fe` |
| ValidatorTimelock            | `0x046b9411436c47038c9e1ef83fd9dd5a1cd9e465` |
| ChainRegistrationSender      | `0xd843114592beed3fe84754f19dda709a5356e50e` |
| BridgedTokenBeacon           | `0x62d15ab56822bf04b57003e13eae9d7a81a5faf3` |
| TransparentProxyAdmin        | `0x9c896ac34c488a806ecab821d4579219382cc2c8` |

The [ecosystem deployment record](https://app.notion.com/p/3bca48363f2380559472f5ed6e0e0c67) supplies these addresses. On 20 October 2026, Sepolia reads confirmed `Governance.owner()` and chain 312 `ChainAdmin.owner()` both return the EOA above; `Bridgehub.owner()`, `CTM.owner()`, and `TransparentProxyAdmin.owner()` return Governance. `L1NativeTokenVault`, `ValidatorTimelock`, `ChainRegistrationSender`, and `BridgedTokenBeacon` return the EOA directly. Both Governance and ChainAdmin use `Ownable2Step`, and neither has a pending owner. The vault and ValidatorTimelock report the EOA itself as pending owner; ChainRegistrationSender reports zero; BridgedTokenBeacon has no `pendingOwner()` entry point. Re-read each value just before handover. `Governance.securityCouncil()` also returns the EOA, and `Governance.minDelay()` is zero. The [ops chain record](https://app.notion.com/p/3dba48363f2381849e6cf26e29a162cb) supplies the L2 RPC. At preparation time that RPC returned HTTP 503, so L2 state and deployment status remain unverified.

## Multisig topology

The deployed Stage topology has **eight distinct 1-of-1 Guardian Safes**, **eight distinct 1-of-1 Security Council Safes**, and **one 1-of-1 foundation Safe**, all with the same owner EOA, `0xd669494442609879b209CcA8eba2BdC904D2E69D`. The Guardians and SecurityCouncil contracts each require exactly eight member addresses. The EmergencyUpgradeBoard requires a foundation signer. The 20 October discussion with Vlad and the user's confirmation select this same 17-Safe layout for Testnet 3. Set their single owner to the Testnet 3 governance EOA above.

The current `zk-governance/l1-contracts/scripts/TestnetDeploy.s.sol` cannot be broadcast as written: it creates twelve council Safes while the current contract requires eight, uses outdated testnet addresses and constructor arguments, and deploys the handler without the current proxy/initializer setup. Deploy a fresh handler implementation and `TransparentUpgradeableProxy`; initialize the proxy with the new council, guardians, and emergency board. Give each Safe a unique nonce, verify all owner/threshold/member links, and record the proxy's `ProxyAdmin` address and owner.

The adjacent [zk-governance-testnet3.patch](./zk-governance-testnet3.patch) adds `Testnet3Config.sol`, `Testnet3Deploy.s.sol`, a Testnet 3 L2 network definition, and `Testnet3DeployVoting.ts` to the separate `zk-governance` repository. Apply it **from that repository's root** with `git apply /path/to/zk-governance-testnet3.patch`, then build the L1 script with `cd l1-contracts && forge build scripts/Testnet3Deploy.s.sol`. The L1 script deploys the 17-Safe Stage topology and the handler proxy; it does not transfer live ownership. Supply `PRIVATE_KEY`, `TESTNET3_SAFE_OWNER`, and `L2_PROTOCOL_GOVERNOR` only in the deployment environment. The script checks that the Safe owner equals the current Testnet 3 control EOA. Review and simulate the resulting transactions before broadcast.

The L2 script requires `DEPLOYER_PRIVATE_KEY`, `TESTNET3_TOKEN_ADMIN`, `TESTNET3_MINT_RECIPIENT`, `TESTNET3_INITIAL_MINT_AMOUNT` (raw token units), `TESTNET3_VOTING_DELAY`, `TESTNET3_VOTING_PERIOD`, `TESTNET3_PROPOSAL_THRESHOLD`, `TESTNET3_INITIAL_QUORUM`, and `TESTNET3_LATE_QUORUM_EXTENSION`. Run it from `zk-governance/l2-contracts` with `npx hardhat run script/Testnet3DeployVoting.ts --network zkSyncTestnet3` after the chain 312 RPC is healthy. It checks the chain ID, minted supply, governor token, timelock roles, and completed receipts. The mint recipient must delegate voting power before a proposal can pass.

The L1 script compiled with Solc 0.8.24 on 20 October 2026. The L2 script was type-checked within the project's TypeScript configuration; the complete TypeScript check still needs generated `artifacts-zk` and `typechain-types`. Read-only Sepolia RPC checks found deployed bytecode at the CREATE3 factory, Safe proxy factory, Safe singleton, and fallback handler addresses. An end-to-end fork simulation still needs the L2 governor address and a funded deployer.

## Deployment sequence

1. Confirm the L2 RPC returns chain ID `312` and Sepolia returns `11155111`. Read the chain's existing L2 token and governance contract addresses before deploying to prevent duplicates.
2. Configure a test voting token using `ZkTokenV1` in `zk-governance/l2-contracts`. Set real testnet admin and initial mint recipient addresses and a useful nonzero supply. Keep private keys out of source and logs.
3. Deploy the L2 `TimelockController` and `ZkProtocolGovernor` against that token. Set voting delay, period, proposal threshold, quorum, and late quorum extension for the intended rehearsal. Grant proposer, canceller, and executor roles to the governor, await every receipt, verify the roles, then renounce the deployer's timelock admin role.
4. Delegate the funded test voter's balance and verify voting power exceeds both the proposal threshold and quorum. Execute a harmless L2 proposal to establish that voting and timelock execution work.
5. Deploy the current `TestnetProtocolUpgradeHandler` implementation and proxy plus its council, guardians, and emergency board using the current `zk-governance` source. Verify all eight constructor references against the addresses above and the L2 governor. Check that proxy initialization set all three governance bodies, and that all Safes are 1-of-1 with the selected owner EOA. Send the **handler proxy address** to Vlad for the governance HTML generation; the implementation address is not the operational handler.
6. Rehearse a harmless end-to-end voted proposal before moving any live ownership. Confirm the L2 governor can drive a proposal into the L1 handler, collect the required Guardian and Council approvals, and execute its L1 call. Record transaction hashes and state changes.
7. Prepare an ownership manifest for **every** directly EOA-owned testnet contract listed above. Governance, ChainAdmin, L1NativeTokenVault, ValidatorTimelock, and ChainRegistrationSender use `Ownable2Step`: the current EOA calls `transferOwnership(handler proxy)` and the handler then calls `acceptOwnership()` in an approved upgrade proposal. Verify `pendingOwner()` before acceptance and `owner()` afterwards. The current pending-owner values on the vault and ValidatorTimelock are already the EOA; the new transfer must replace those values with the handler proxy. BridgedTokenBeacon is an OpenZeppelin `UpgradeableBeacon` with one-step `transferOwnership`, so it has no acceptance transaction. Execute its transfer only once the handler is proven able to operate and the chosen final owner is confirmed. Preserve indirect ownership already held by Governance unless a separate migration is intended.
8. Plan the legacy `Governance.securityCouncil()` role explicitly. It is currently the EOA and is independent of the handler's SecurityCouncil contract. `Governance.updateSecurityCouncil()` is `onlySelf` and requires a scheduled Governance operation. The new council is a signature-verification contract, not a general-purpose caller of `Governance.executeInstant`; assigning it directly would disable that instant-execution path. Decide the replacement or removal of this EOA role before the handover. If changing it, execute and verify that operation while the current EOA still owns Governance.
9. Simulate the complete ordered handover on a Sepolia fork, then broadcast from the authorized owner and voting accounts. Verify final owners, pending owners, handler references, Safe owner/thresholds, and that the EOA no longer has the authority intended to move. Record deployed addresses, transaction hashes, source commit, compiler settings, voting parameters, role checks, and proposal results.

The current L2 scripts contain a placeholder token address, zero initial token supply, and test-only voting parameters. They cannot be used unchanged for this deployment. The governor deployment script also submits timelock role transactions without awaiting their receipts before renouncing admin, so its sequencing needs correction.

## Inputs to settle before broadcast

- The funded L2 deployer, token admin, mint recipient, and voting account addresses.
- Voting supply and timing/threshold/quorum values.
- Confirmation of the Testnet 3 Safe owner EOA and the foundation signer.
- The replacement for the legacy Governance security-council EOA role.
- Signing access to the current EOA for ownership transfer and to the voting/approval accounts for acceptance.
- A healthy chain 312 RPC and verification of current L2 state.
