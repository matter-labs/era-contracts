# Threat model: ZKsync era-contracts

## What this project does and where untrusted input enters

era-contracts holds the protocol contracts of ZKsync chains (the ZK Stack):

- `l1-contracts/`, the settlement contracts on Ethereum. These are `L1Bridgehub`; the shared bridge
  (`L1AssetRouter`, `L1NativeTokenVault`, `L1Nullifier`); the chain type managers; and one diamond proxy per
  chain whose facets (`Committer`, `Executor`, `Mailbox`, `Admin`, `Getters`) commit batches, verify proofs,
  run the priority queue and store batch commitments. The same tree holds the L2 halves of the bridge
  (`L2AssetRouter`, `L2NativeTokenVault`, `BridgedStandardERC20`) and the L2 base token (`L2BaseTokenEra`, and
  `BaseTokenHolder`, whose reserve pays out base token in place of minting).
- `system-contracts/`, the EraVM system contracts and the bootloader: `bootloader/bootloader.yul`,
  `ContractDeployer`, `NonceHolder`, `L1Messenger`, `MsgValueSimulator`, `KnownCodesStorage`,
  `AccountCodeStorage`, `Compressor`, `SystemContext`, `DefaultAccount`, the EVM emulator
  (`EvmEmulator.yul`, `EvmGasManager.yul`) and the Yul precompiles (`precompiles/`).
- `l2-contracts/`, L2 helpers. `da-contracts/`, the L1 DA validators and `EIP7702Checker`, which `Mailbox`
  uses to decide L1->L2 sender aliasing.

All chains share one set of L1 bridge contracts, so the escrow of every chain sits behind the same code.
L1 does not cap what each chain can withdraw (per-chain balances were removed, see `docs/bridging.md`): only
the proofs stop a chain from withdrawing funds deposited into other chains. This is by design; do not report
the missing cap. The one cap left on L1 is `L1NativeTokenVault.bridgedOut`, the total of each L1-native asset
bridged out to all chains, which `populateBridgedOut` fills in for escrow from before the upgrade.

Untrusted input:

- Any L1 account: deposits and L1->L2 transactions through `L1Bridgehub` and `Mailbox`, withdrawal
  finalization and failed-deposit claims with Merkle proofs (`L1Nullifier`, `L1AssetRouter`), and every
  other permissionless entry point. An L1 contract acts on L2 only from its aliased address
  (`AddressAliasHelper`); `Mailbox` leaves EOAs and EIP-7702 accounts (`EIP7702Checker`) unaliased.
- Any L2 account: transactions processed by the bootloader, including custom accounts and paymasters;
  calls into the system contracts; contract deployment, EraVM bytecode and EVM bytecode run by the
  emulator; precompile inputs; withdrawals and L2->L1 messages.
- Tokens: anyone can bridge an arbitrary ERC-20, including malicious, reentrant, fee-on-transfer and rebasing
  ones. A token like that is a threat only as an attack vector against other people's funds: other users'
  balances, the bridge's holdings of other tokens, or other chains' escrow. A token that is not widely used is
  not itself a target. If a non-standard token only loses, freezes or misaccounts its own bridged balance, so
  that only the people who chose to hold it are affected, do not report it.
- Custom asset handlers and asset deployment trackers: anyone can deploy one, and it is trusted only for
  its own asset.
- Batch data, DA pubdata and proofs submitted by chain operators (see the trust assumptions below).

## Trust assumptions

- Ecosystem governance is trusted. That covers `Governance`, the owners of `L1Bridgehub` and the chain type
  managers, and protocol upgrades. Report any path by which someone other than governance reaches these
  powers.
- A chain admin (`ChainAdmin`, bounded by restrictions such as `PermanentRestriction`) is trusted for its own
  chain only. A malicious chain (its admin, its operator and its L2 users acting together) must not be able
  to take funds escrowed for other chains, mint unbacked tokens that other chains or L1 honour, forge
  messages attributed to another chain, or escape the restrictions the ecosystem places on chain admins.
- Operators and validators (`ValidatorTimelock`) may delay or refuse to process batches. They must not be
  able to get a batch executed without a valid proof, execute a batch that differs from what was committed,
  skip, reorder or forge priority transactions, or bypass the execution delay.
- The proof system itself (circuits and provers) is out of scope: assume a proof that verifies attests to
  the bootloader and system contracts having run as written. That makes their logic in scope. A bug in
  them is a bug in what the chain proves. So are the on-chain verifiers (`EraVerifierPlonk`,
  `EraVerifierFflonk`, `EraDualVerifier`) and the public input that `Executor` computes and passes to them.
  Any gap between what is committed and what is proven is critical.
- ZKsync OS chains share the L1 contracts and the escrow, but their proofs attest to ZKsync OS, which lives in
  another repository: assume such a proof attests to ZKsync OS having run as written. Their L1 side
  (`ZKsyncOSChainTypeManager`, `ZKsyncOSVerifier`, `ZKsyncOSVerifierPlonk`, `DefaultUpgradeZKsyncOS`,
  `BlobsL1DAValidatorZKsyncOS`) is in scope, since a bug there reaches every chain's escrow.
- Inside EraVM, system contracts are privileged: functions restricted to the bootloader, to system calls or
  to other system contracts must not be reachable by an ordinary L2 account.
- `EraTestnetVerifier`, `ZKsyncOSTestnetVerifier` and `TestnetPaymaster` are never used on mainnet. Findings
  that need them are out of scope.

## Gateway

Gateway is not used in production: every chain settles on L1, and chain migrations between settlement layers
are disabled in code. `CHAIN_MIGRATIONS_ENABLED` is `false` in `common/Config.sol`, and `whenMigrationsEnabled`
makes the chain asset handlers' `bridgeBurn` and `bridgeMint` revert. Lifting it takes a protocol upgrade, not
a governance call (`docs/chain-lifecycle.md`). A finding must work while every chain settles on L1 and the flag
is `false`. Any path that migrates a chain while the flag is `false` is Critical.

Out of scope: what happens once a chain settles on or migrates to a Gateway, and the code that only serves
Gateway: `state-transition/chain-deps/gateway-ctm-deployer/`, `GatewayTransactionFilterer`, `CalldataDAGateway`,
`RelayedSLDAValidator` and `CTMDeploymentTracker`.

Gateway code that is reachable while every chain settles on L1 stays in scope, rated by its impact on chains
that settle on L1. That includes:

- the entry points of the chain asset handlers and their checks (`onlyAssetRouter`, the chain admin check,
  `whenMigrationsEnabled`);
- `L1ChainAssetHandler.bridgeConfirmTransferResult`, which the flag deliberately does not gate, and the
  `forwardedBridgeConfirmTransferResult` calls it makes into the chain type manager and the `Migrator` facet;
- `Migrator.pauseDepositsBeforeInitiatingMigration` and `Migrator.unpauseDeposits`;
- the settlement-layer hop that `MessageHashing` still accepts in L2->L1 message proofs, and
  `L1ChainAssetHandler.isValidSettlementLayer` as `L1MessageRoot` calls it;
- any other branch for a settlement layer other than L1 that an L1 or L2 user can enter.

## EVM emulator

EVM emulation is enabled on ZKsync Era mainnet, and any other EraVM chain can enable it
(`Admin.allowEvmEmulation`). Every EVM contract runs `EvmEmulator.yul` on attacker-written bytecode. The
privilege belongs to the account: `ContractDeployer` (`onlySystemCallFromEvmEmulator`) and `EvmGasManager`
accept a system call from any account that `AccountCodeStorage` marks as EVM, and any EraVM code can make a
system call. The emulator also makes system calls to `MsgValueSimulator` and handles raw calldata and
returndata pointers. EraVM does not enforce STATICCALL between EVM contracts; the static flag that the caller
hands over through `EvmGasManager` does. For any EVM bytecode:

- only `EvmEmulator.yul` runs as an account marked EVM: no DELEGATECALL from an EVM contract into EraVM code,
  and no EraVM code at an address marked EVM;
- the target of a call the bytecode directs never receives a system call, including the call that
  `MsgValueSimulator` forwards for a call with value, and gets no calldata beyond the opcode's operands;
- no state changes inside a STATICCALL;
- storage is written and value moved only for the executing account;
- the gas and static flag pushed to `EvmGasManager` reach only the callee they were pushed for: a call that
  fails, or never reaches an EVM callee, leaves none for a later one;
- contracts are deployed only to the address CREATE or CREATE2 would give on Ethereum, and never over
  existing code.

EraVM and compiler (zksolc, LLVM) bugs are out of scope on their own. An EraVM or compiler behaviour that EVM
bytecode can reach through the emulator and that breaks a rule above is in scope as an emulator finding.

The differences from Ethereum listed in
https://docs.zksync.io/zksync-protocol/era-vm/evm-interpreter/evm-differences are known; do not report them.
Any other difference that breaks a guarantee Ethereum contracts rely on for safety (the 2300-gas stipend, the
63/64 rule, CREATE2 addresses, EXTCODEHASH and EXTCODESIZE) is rated by its impact on contracts deployed on
Era, not as Medium by default. Warm and cold access state (EIP-2929) lasts for the whole transaction, as on
Ethereum; an error in it is rated by its effect on gas.

## Components that matter most / least

Highest priority (they hold funds, mint base token, or decide what L1 accepts):

- The EVM emulator: `system-contracts/contracts/EvmEmulator.yul`, `EvmGasManager.yul`, `EvmHashesStorage`,
  `EvmPredeploysManager`, and the EVM paths of `ContractDeployer` and `AccountCodeStorage`.
- `l1-contracts/contracts/bridge/`: `L1AssetRouter`, `L1NativeTokenVault`, `L1Nullifier`, `AssetRouterBase`,
  `NativeTokenVaultBase`, the L2 halves, `BridgedStandardERC20`, `L2WrappedBaseToken`.
- `l1-contracts/contracts/core/`: `L1Bridgehub`, `L1MessageRoot`, and the entry points of
  `L1ChainAssetHandler` that are reachable while every chain settles on L1 (see Gateway); and
  `l1-contracts/contracts/interop/L2MessageVerification.sol`.
- `l1-contracts/contracts/state-transition/`: the chain type managers, `validators/ValidatorTimelock`,
  `chain-deps/` (the diamond, its storage and all facets, including the L1->L2 sender aliasing in
  `Mailbox`), `libraries/` (`PriorityTree`, `PriorityQueue`, `BatchDecoder`, `TransactionValidator`, ...),
  `verifiers/`, `data-availability/`.
- `l1-contracts/contracts/common/`: `MessageVerification` and `libraries/` (Merkle trees and proofs,
  `MessageHashing`, `DataEncoding`, `UnsafeBytes`).
- `system-contracts/`: the bootloader (fee and refund accounting, transaction validation, L1->L2
  transaction processing, pubdata and L2->L1 log publishing), `MsgValueSimulator`, and in
  `l1-contracts/contracts/l2-system/`, `era/L2BaseTokenEra.sol` and `BaseTokenHolder.sol` (base token supply:
  payouts from the holder's reserve replace minting), `NonceHolder` and account abstraction rules,
  `ContractDeployer`, `KnownCodesStorage` and `AccountCodeStorage` (which bytecode runs at an address),
  `L1Messenger`, `Compressor` and `libraries/L2DAValidator.sol` (what reaches L1), and the precompiles,
  especially signature verification (`Ecrecover`, `P256Verify`) and the elliptic-curve ones.
- `da-contracts/contracts/`: the L1 DA validators and `EIP7702Checker`.
- `l1-contracts/contracts/governance/` and `upgrades/`: `ChainAdmin` and its restrictions, `Governance`,
  `ServerNotifier`, the upgrade contracts (a non-governance actor triggering an upgrade, or an upgrade
  corrupting state); `l1-contracts/contracts/l2-upgrades/` (`L2ComplexUpgrader` and the L2 genesis and
  upgrade contracts).

Lower priority: `l2-contracts/contracts/ConsensusRegistry.sol` and `da-contracts/contracts/da-layers/`.

In scope without a section here yet, rated by the severity rules below: `l1-contracts/contracts/interop/`
(other than `L2MessageVerification`), `l1-contracts/contracts/atomic-interop/`, `L2AssetTracker`,
`PrividiumTransactionFilterer`, the validators other than `ValidatorTimelock` (`EraMultisigValidator`,
`MultisigCommitter`, `PermissionlessValidator`), and the ZKsync OS L2 contracts
(`l1-contracts/contracts/l2-system/zksync-os/`, `L2NativeTokenVaultZKOS`).

Out of scope: `dev-contracts/`, `test-contracts/`, `test/`, `deploy-scripts/`, `scripts/`, `upgrade-system/`,
`tools/`, `lib/`, `Dummy*` contracts, `EraTestnetVerifier`, `ZKsyncOSTestnetVerifier`, `TestnetPaymaster`,
and the Gateway-only code listed under Gateway.

## How to exercise it

- Everything, tests included, is already compiled with foundry-zksync: `da-contracts` and `l1-contracts` for EVM
  (`*/out`), and `l1-contracts`, `l2-contracts` and `system-contracts` for EraVM (`*/zkout`). `FOUNDRY_OFFLINE=true`
  is set, so forge never tries to fetch a compiler.
- L1 contracts, as CI runs them: `cd l1-contracts && yarn test:foundry`. This runs
  `forge test --threads 1 --ffi --match-path 'test/foundry/{l1,zksync-os}/*'`, skipping the mainnet-fork test.
  After editing a core contract, the recompile takes about a minute.
  Unit tests per component are in `l1-contracts/test/foundry/l1/unit/concrete/`. Fixtures that deploy a whole
  ecosystem (Bridgehub, chain type manager, chains, tokens) are in
  `l1-contracts/test/foundry/l1/integration/_Shared*.sol`. A proof of concept is most useful as a Foundry
  test that extends these fixtures. If one reverts with `Can't acquire config lock`, an earlier run died holding
  it: delete `l1-contracts/test/foundry/l1/integration/deploy-scripts/script-config/.lock`.
- `_SharedGatewayDeployer.t.sol` (`_enableChainMigrationsForTesting`) and some other tests swap in
  `L1ChainAssetHandlerDev` or `L2ChainAssetHandlerDev`, which turn chain migrations back on. A reproducer that
  needs them shows a path that cannot happen in production.
- L2-side bridge and messaging tests in EraVM mode: `cd l1-contracts && yarn test:zkfoundry`.
- L2 contracts: `cd l2-contracts && yarn test:foundry`.
- System contracts, the bootloader and the EVM emulator have no offline harness in this image. Their hardhat
  tests need a running anvil-zksync node, and the bootloader tests are a Rust crate. Reason from the code. Where
  a `forge test --zksync` reproducer is possible, note that foundry-zksync runs its own bundled system
  contracts, not the ones in this tree. For the emulator, give the EVM bytecode (or its Solidity source) and the
  calls that trigger the issue, traced through `EvmEmulator.yul`.
- Mainnet-fork tests need an RPC endpoint and cannot run here.

## How we rate severity

- Critical: theft or permanent freezing of funds held by the L1 bridge contracts or of bridged tokens on L2;
  minting unbacked tokens or base token; finalizing a withdrawal twice, or one never initiated on L2;
  forging an L2->L1 message, or one attributed to another chain; an L1 contract acting on L2 from its own,
  unaliased address; L1 executing a batch that was not proven, or whose proven public input differs from what
  was committed; one chain spending or minting against another chain's balance; an ordinary L2 account
  reaching a system-only function, changing another account's nonce or code, or passing validation for an
  account it does not control; EVM bytecode that breaks one of the emulator rules above; migrating a chain
  while migrations are disabled; a precompile that accepts a forged signature; taking over governance, an
  upgrade path or another chain's admin.
- High: temporary freezing of funds; blocking deposits or withdrawals for every chain, or for a chain other
  than the attacker's; skipping, reordering or censoring priority transactions; a transaction that halts
  batch production, produces a batch that cannot be proven, or bricks a chain so that only a governance
  upgrade recovers it; fee or refund accounting in the bootloader that lets users steal from the operator or
  from each other; a chain admin escaping an enforced restriction with bounded impact.
- Medium: EVM emulator or precompile behaviour that differs from Ethereum with limited impact; griefing with
  bounded impact that recovers without governance; a single user's or asset's flow stuck but recoverable.
- Low: events, getters and view functions; issues that need trusted governance to misconfigure something.

## How we would like reports and patches

- One root cause per report. Where the code can be exercised here, the reproducer is a Foundry test that
  runs offline with the commands above; name its file and test.
- State the attacker's role (any L1 or L2 user, token or asset-handler deployer, chain admin, operator) and
  any configuration the attack needs.
- Keep patches minimal. These contracts sit behind upgradeable proxies, and system contracts live at fixed
  addresses with fixed storage: never reorder, retype or remove storage variables. A change to a system
  contract or the bootloader changes the hashes in `AllContractsHashes.json`; say so in the patch.

## Anything to leave alone

- Findings already in `audits/`.
- The power of the trusted roles above, and misconfiguration by them.
- Issues confined to one non-standard or little-used token that affect only that token's own holders.
- Gas optimizations, style and natspec.
