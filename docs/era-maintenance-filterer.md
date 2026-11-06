# Era maintenance-mode transaction filterer

`EraMaintenanceTransactionFilterer` implements the L1 side of the maintenance-mode limits for EraVM
chains: deposits are limited to whitelisted tokens and capped amounts, and other L1→L2 transactions
(priority operations) can be restricted to withdrawals. It plugs into the existing
`ITransactionFilterer` hook of the Mailbox, so it needs no protocol upgrade, and the chain admin can
reconfigure, replace or unset it with one transaction.

Transactions sent directly on L2 never reach the L1 filterer. Restrictions on them, including the
ban on new contract deployments, are applied by the sequencer and are out of scope here.

## Deployment and ownership

Each EraVM chain gets its own proxy, owned by its chain admin, whose `initialize(owner, chainId)`
(which reverts for a chain the Bridgehub has no base token for) leaves it in the permissive configuration:

- `callMode = ALLOW_ALL`;
- the chain's base token uncapped (`depositCap = type(uint256).max`), so no transaction is blocked
  on `mintValue`;
- no other token accepted;
- the withdrawal functions of the L2 base token (`withdraw`, `withdrawWithMessage`) and of the L2
  asset router (`withdraw(bytes32,bytes)` and the legacy `withdraw(address,address,uint256)`)
  registered for `WITHDRAWALS_ONLY` mode.

Before setting the filterer on the chain, the admin whitelists the tokens that are already bridged
(`setDepositCaps` with `type(uint256).max`); a token left out is rejected from the moment the
filterer is set, even in `ALLOW_ALL` mode. The admin also adds the exemptions, legacy bridges and withdrawal
functions the chain needs (see [Configuration checklist](#configuration-checklist)). Every later
change is a single owner call that emits an event.

## Rules

`isTransactionAllowed` evaluates, in order:

1. **Pointed whitelisted hash.** If
   `allowedTxHashes[getTxHash(sender, contractL2, l2Value, l2Calldata, refundRecipient)]` is set, the
   transaction passes. `mintValue` is not hashed, because it includes the L1 base cost,
   which depends on the gas price at submission. The filter is a `view` function, so an entry is not
   consumed: the same transaction can be replayed until the admin removes it, each time with any
   `mintValue`, so an entry also lifts the base token cap for that sender. `sender` and
   `refundRecipient` are the values the Bridgehub passes to the Mailbox: `sender` is the second
   bridge for two-bridges requests, and `refundRecipient` defaults to the Bridgehub caller when it is
   zero, but is not yet aliased (the Mailbox aliases it only after the filter runs), so the hash must
   be built from those, not from the user's raw request. Requests made directly through the Era
   Mailbox's legacy `requestL2Transaction` (used by Lido and other legacy integrators) do not go
   through the Bridgehub: there `sender` is the caller and `refundRecipient` is the raw argument.
2. **Exempt sender.** If `exempt[sender]`, the transaction passes.
3. **Deposits.** The depositor is decoded from the calldata (see [Deposit decoding](#deposit-decoding)).
   An exempt depositor passes in either mode. Any other deposit is rejected in `WITHDRAWALS_ONLY`
   mode, and in `ALLOW_ALL` mode both its token amount and `mintValue` must be within their caps.
   - **Through the Bridgehub.** If `sender` is the L1 asset router, the transaction is a token
     deposit. It must target the L2 asset router with `l2Value == 0`; any other message of the router
     (for example registering a custom asset handler) is rejected, as is a new-encoding deposit of an
     asset whose handler is not the native token vault, since its transfer data is handler-defined.
   - **Through a legacy bridge.** If `sender` is registered in `legacyBridges` and the calldata calls
     the legacy `finalizeDeposit`, the transaction is checked like a Bridgehub deposit. Other calls of
     the bridge are generic calls. The decoded `l1Sender` is trusted as the depositor, so only bridges
     that set it to their caller should be registered.
4. **Generic calls.** Any other call passes if `mintValue` is within the base token cap. In
   `WITHDRAWALS_ONLY` mode it must also call a `(contractL2, selector)` pair registered in
   `withdrawalFunctions`, so users can still force a withdrawal from L1.

A cap applies to a single deposit, and a cap of zero means the asset is not accepted. The cap of the
base token bounds `mintValue`, i.e. all base token entering the chain through a non-exempt priority
operation, fees included. Setting it to zero blocks every non-exempt, non-whitelisted transaction,
including forced withdrawals.

`WITHDRAWALS_ONLY` limits what an L1→L2 call can do, not how much base token it mints: a call to a
registered withdrawal function brings in up to the base token cap, and whatever the L2 call does
not spend is refunded on L2. Switching to `WITHDRAWALS_ONLY` therefore goes together with lowering
the base token cap to about the fee of a withdrawal. A forced withdrawal does not need its value in
`mintValue`, since `l2Value` can come from the sender's existing L2 balance. The sender is the L1
caller itself for an EOA or an EIP-7702 account and its alias for a contract, so a contract's forced
withdrawal spends its alias's balance.

## Deposit decoding

Era's priority operations carry two `finalizeDeposit` encodings, and both are decoded:

| Encoding                                                                                             | Selector     | Asset id                                                | Depositor                                                             |
| ---------------------------------------------------------------------------------------------------- | ------------ | ------------------------------------------------------- | --------------------------------------------------------------------- |
| `finalizeDeposit(uint256 chainId, bytes32 assetId, bytes transferData)`                              | `0x9c884fd1` | from the calldata                                       | `originalCaller` of `DataEncoding.decodeBridgeMintData(transferData)` |
| `finalizeDeposit(address l1Sender, address l2Receiver, address l1Token, uint256 amount, bytes data)` | `0xcfe7af7c` | `DataEncoding.encodeNTVAssetId(block.chainid, l1Token)` | `l1Sender`                                                            |

The Era L1 asset router builds the legacy encoding for every L1-native token, including every
`L1ERC20Bridge` deposit, and the new one for the rest, such as tokens bridged back from L2. In the
legacy encoding the trailing `data` holds token metadata, not transfer data, and the asset id is
derived as the one of an L1-native NTV token.

Custom bridges that call their L2 counterpart through the Mailbox with the same legacy ABI, such as
the Lido bridge, are registered with `setLegacyBridge`. Their deposits are then capped by the
derived asset id of the L1 token; leaving that cap at zero blocks their deposits while their
withdrawals stay reachable through `withdrawalFunctions`.

## Configuration checklist

- **Tokens.** Every token to keep accepting, with its cap.
- **Legacy shared bridge.** The legacy L2 shared bridge of the chain is not a built-in address, so
  its `withdraw(address,address,uint256)` is registered with `setWithdrawalFunction`.
- **Custom bridges.** Each custom bridge is registered with `setLegacyBridge`, and its L2
  `withdraw` with `setWithdrawalFunction`.
- **Tokens native to L2.** The L2 native token vault burns a token bridged from L1 without an
  allowance, but takes a token native to L2 (such as ZK) with `transferFrom`, so its withdrawal
  needs an `approve` of the vault first. For its holders to force a withdrawal in
  `WITHDRAWALS_ONLY` mode, the token's `approve` is registered with `setWithdrawalFunction`.
- **Wrapped base token.** Holders of L2 WETH unwrap it before withdrawing the base token, so its
  `withdraw(uint256)` is registered with `setWithdrawalFunction`.
- **Third-party bridges and protocols.** Senders whose L1→L2 messages must keep working, such as
  Across's HubPool (which settles relayer refunds through priority operations), are either
  exempted or the restrictions that would affect them are enabled only after they close their
  routes. An exemption covers the transactions the account sends itself and, in either mode, the
  token deposits it makes through the asset router or a registered legacy bridge.
- **Ecosystem senders.** Contracts such as `CTMDeploymentTracker` and `ChainRegistrationSender`
  send two-bridges requests to the L2 Bridgehub, which are generic calls and are rejected in
  `WITHDRAWALS_ONLY` unless their sender is exempt.
- **Governance.** The ZK Nation `Guardians` contract cancels and proposes L2 governor proposals
  through the Era Mailbox's `requestL2Transaction`. These are generic calls too, so it is exempted
  before switching to `WITHDRAWALS_ONLY`.

## Design decisions

- **Cap per deposit.** Per-account and per-time-window caps need extra state and accounting on
  every deposit, while the goal is only to make funding the chain unattractive. A cap per deposit
  can be bypassed by splitting a deposit into many small ones.
- **Standalone filterer.** Hardcoding the restrictions in the Mailbox would make every change a
  protocol upgrade and prevent reuse across EraVM chains.
- **Factory dependencies.** The filterer does not see `factoryDeps`, so it cannot block priority
  operations that publish bytecode. Blocking them would need a Mailbox change.
- **Failure mode.** The filterer sits on every priority operation, so a bug could block deposits
  and forced withdrawals. The logic is kept small, malformed deposit calldata reverts instead of
  passing, and the admin can unset the filterer with one transaction.
