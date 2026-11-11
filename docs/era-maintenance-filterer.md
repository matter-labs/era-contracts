# Era maintenance-mode transaction filterer

`EraMaintenanceTransactionFilterer` restricts the L1→L2 transactions (priority operations) of an
EraVM chain in maintenance mode: deposits are limited to whitelisted tokens, with a cap per
deposit, other priority operations can be limited to forced withdrawals, and calls to the L2
deployers are rejected. It plugs into the Mailbox's existing `ITransactionFilterer` hook,
so it needs no protocol upgrade, and the chain admin sets, reconfigures or unsets it with one
transaction. Transactions sent on L2 and inbound interop never reach it (see
[Limits and design decisions](#limits-and-design-decisions)).

## Rules

The filterer has two modes, `ALLOW_ALL` and `WITHDRAWALS_ONLY`. `isTransactionAllowed` goes
through the rows below in order, and the first row that matches decides.

| Priority operation                                        | `ALLOW_ALL`                                                      | `WITHDRAWALS_ONLY`                                                                               |
| --------------------------------------------------------- | ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| Its hash is whitelisted ([pointed hash](#pointed-hashes)) | passes                                                           | passes                                                                                           |
| Its sender is [exempt](#exemptions)                       | passes                                                           | passes                                                                                           |
| A [deposit](#deposits) by an exempt depositor             | passes                                                           | passes                                                                                           |
| Any other deposit                                         | passes if the token amount and `mintValue` are within their caps | rejected                                                                                         |
| Any other message of the L1 asset router                  | rejected                                                         | rejected                                                                                         |
| A call to the L2 `ContractDeployer` or `Create2Factory`   | rejected                                                         | rejected                                                                                         |
| Any other (generic) call                                  | passes if `mintValue` is within the base token cap               | passes if it calls a registered withdrawal function and `mintValue` is within the base token cap |

- **Caps.** `depositCap` is set per asset id and applies to a single deposit. A cap of zero means
  the asset is not accepted.
- **Base token cap.** The base token's cap bounds `mintValue`, i.e. all base token a non-exempt
  priority operation brings in, fees included. A zero base token cap rejects everything the first
  three rows do not let through, forced withdrawals included.
- **Withdrawal functions.** `withdrawalFunctions` holds `(contractL2, selector)` pairs. They keep
  forced withdrawals from L1 working in `WITHDRAWALS_ONLY` mode.

## Setup

Each EraVM chain gets its own proxy, owned by its chain admin. `initialize(owner, chainId)` reverts
for a chain the Bridgehub has no base token for, and starts permissive:

- `callMode = ALLOW_ALL`;
- the chain's base token uncapped (`depositCap = type(uint256).max`);
- no other token accepted;
- the withdrawal functions of the L2 base token (`withdraw`, `withdrawWithMessage`) and of the L2
  asset router (`withdraw(bytes32,bytes)` and the legacy `withdraw(address,address,uint256)`)
  registered.

Even so, the filterer rejects deposits of every token not whitelisted, and calls to the L2
deployers, from the moment it is set. The admin therefore works through the checklist below
before setting it. Every later change is a single owner call that emits an event.

- **Tokens.** `setDepositCaps` for every token already bridged to the chain, with
  `type(uint256).max` or a lower cap.
- **Governance.** Exempt the ecosystem governance (the `ProtocolUpgradeHandler` on Era). An
  upgrade that sends an L2 call executes atomically, so a rejected call reverts the whole upgrade,
  and the filterer is owned by the chain admin, so governance cannot lift a rejection itself.
- **Legacy shared bridge.** The chain's legacy L2 shared bridge is not a built-in address, so
  register its `withdraw(address,address,uint256)` with `setWithdrawalFunction`.
- **Custom bridges.** Register each with `setLegacyBridge` (see [Deposits](#deposits)), and its L2
  `withdraw` with `setWithdrawalFunction`.
- **Tokens native to L2**, such as ZK. The L2 native token vault burns a token bridged from L1
  without an allowance, but takes a token native to L2 with `transferFrom`, so withdrawing it needs
  an `approve` of the vault first. Register the token's `approve` with `setWithdrawalFunction`, so
  its holders can force a withdrawal in `WITHDRAWALS_ONLY` mode.
- **Wrapped base token.** Holders of L2 WETH unwrap it before withdrawing the base token, so
  register its `withdraw(uint256)` with `setWithdrawalFunction`.
- **Third-party senders** whose L1→L2 messages must keep working, such as Across's HubPool (which
  settles relayer refunds through priority operations). Either exempt them (see
  [Exemptions](#exemptions)) or enable the restrictions that would affect them only after they
  close their routes.

## Details

### Pointed hashes

An entry in `allowedTxHashes` whitelists one exact transaction, keyed by
`getTxHash(sender, contractL2, l2Value, l2Calldata, refundRecipient)`.

- `mintValue` is not hashed: it includes the L1 base cost, which depends on the gas price at
  submission.
- An entry is not consumed, since the filter is a `view` function. The same transaction can be
  replayed until the admin removes the entry, each time with any `mintValue`, so an entry also
  lifts the base token cap for that transaction.
- The hash is built from the values the Bridgehub passes to the Mailbox, not from the user's raw
  request. `sender` is the second bridge for two-bridges requests. `refundRecipient` defaults to
  the Bridgehub caller when it is zero, and is not yet aliased (the Mailbox aliases it only after
  the filter runs).
- Requests made directly through the Era Mailbox's legacy `requestL2Transaction` (used by Lido and
  other legacy integrators) do not go through the Bridgehub: there `sender` is the caller and
  `refundRecipient` is the raw argument.

### Exemptions

An exemption covers the transactions the account sends itself and the token deposits it makes
through the asset router or a registered legacy bridge, in either mode and with no cap. It
therefore also covers whatever the account can be made to send. Only exempt a sender whose L1→L2
transactions are access-controlled, or fixed in target, calldata, `mintValue` and refund
recipient. A contract that forwards its caller's request, or lets its caller choose the gas limit
and receive the L2 refund, would let anyone deposit through it.

### Deposits

A priority operation is a deposit when it calls `finalizeDeposit` (either encoding below) and
comes from one of these senders:

- **The L1 asset router** (deposits through the Bridgehub). It must target the L2 asset router with
  `l2Value == 0`, and in the new encoding the asset's handler must be the native token vault, since
  the transfer data of other handlers is handler-defined. Any other message of the router, for
  example registering a custom asset handler, is rejected, even when the depositor is exempt.
- **A registered legacy bridge** (`setLegacyBridge`), when the calldata calls the legacy
  `finalizeDeposit`. Its other calls are generic calls. The decoded `l1Sender` is trusted as the
  depositor, so register only bridges that set it to their caller.

The asset, amount and depositor are decoded from either of Era's two `finalizeDeposit` encodings:

| Encoding                                                                                             | Selector     | Asset id                                                | Depositor                                                             |
| ---------------------------------------------------------------------------------------------------- | ------------ | ------------------------------------------------------- | --------------------------------------------------------------------- |
| `finalizeDeposit(uint256 chainId, bytes32 assetId, bytes transferData)`                              | `0x9c884fd1` | from the calldata                                       | `originalCaller` of `DataEncoding.decodeBridgeMintData(transferData)` |
| `finalizeDeposit(address l1Sender, address l2Receiver, address l1Token, uint256 amount, bytes data)` | `0xcfe7af7c` | `DataEncoding.encodeNTVAssetId(block.chainid, l1Token)` | `l1Sender`                                                            |

The Era L1 asset router builds the legacy encoding for every L1-native token, including every
`L1ERC20Bridge` deposit, and the new one for the rest, such as tokens bridged back from L2. In the
legacy encoding the trailing `data` holds token metadata, not transfer data.

Once registered, a custom bridge with the same legacy ABI, such as Lido's, is capped by the asset id derived from
its L1 token. A zero cap blocks its deposits, while its withdrawals stay reachable through
`withdrawalFunctions`. That asset id is also the one of the token's deposits through the asset
router, so the custom bridge and the asset router share one cap for the same L1 token. This is a
known limitation.

### The base token cap in `WITHDRAWALS_ONLY` mode

`WITHDRAWALS_ONLY` limits what an L1→L2 call can do, not how much base token it brings in. A call
to a registered withdrawal function can bring in up to the base token cap, and whatever the L2 call
does not spend is refunded on L2. Switching to `WITHDRAWALS_ONLY` therefore goes together with
lowering the base token cap to about the fee of a withdrawal.

- The cap is fixed in wei while the fee follows the L1 gas price, so the cap is sized for the
  highest gas price at which forced withdrawals must still pass. Above that price they are
  rejected; below it the difference is refunded on L2 and can be used to deposit.
- A forced withdrawal does not need its value in `mintValue`: `l2Value` can come from the sender's
  existing L2 balance. The sender is the L1 caller itself for an EOA or an EIP-7702 account, and
  its alias for a contract, so a contract's forced withdrawal spends its alias's balance.

### Withdrawals from L2 contract accounts

Funds held by an L2 contract account, such as a smart account or an L2 Safe, cannot be withdrawn
through `withdrawalFunctions`: the withdrawal has to be a call from the account, so the L1
transaction targets the account itself, which is not a registered withdrawal function. Such an
account can withdraw through a pointed hash of its withdrawal transaction, if it accepts that call
from an L1 sender (a Safe does, given its owners' signatures). Registering its execution function
instead (for a Safe, `execTransaction` on that Safe's address) would let through any transaction
its owners sign, not only withdrawals.

## Limits and design decisions

- **Transactions sent on L2** never reach the L1 filterer. The sequencer restricts them, including
  the ban on new contract deployments.
- **Inbound interop.** Anyone can call `InteropHandler.executeBundle` on L2, and a bundle can mint
  tokens and base token without a priority operation. `executeBundle` reverts while the chain
  settles on L1, as Era does.
- **Deployments.** The sequencer cannot skip a priority operation, so the filterer rejects calls to
  the `ContractDeployer` and the public `Create2Factory` in either mode, unless the sender is
  exempt or the transaction has a pointed hash. This does not block every deployment:
  - in `ALLOW_ALL` mode a priority operation can still call any factory contract on L2 (on Era, for
    example, the deterministic-deployment proxy `0x4e59b44847b379578588920cA78FbF26c0B4956C` or
    CreateX `0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed`);
  - a bytecode already known on L2 needs no `factoryDeps`;
  - where EVM bytecode is allowed, as on Era, an EVM factory deploys any init code from the
    calldata.

  None of Era's priority operations from 2025-11-06 to 2026-11-09 called either deployer. The 10
  that deployed a contract were first deposits of a token, for which the L2 bridge deploys the
  token's proxy.

- **Factory dependencies.** The filterer does not see `factoryDeps`, so it cannot block priority
  operations that publish bytecode. Blocking them would need a Mailbox change.
- **Cap per deposit.** A deposit split into many small ones bypasses it. Per-account and
  per-time-window caps would need extra state and accounting on every deposit, while the goal is
  only to make funding the chain unattractive.
- **Standalone filterer.** Hardcoding the restrictions in the Mailbox would make every change a
  protocol upgrade and prevent reuse across EraVM chains.
- **Failure mode.** The filterer sits on every priority operation, so a bug could block deposits
  and forced withdrawals. The logic is kept small, malformed deposit calldata reverts instead of
  passing, and the admin can unset the filterer with one transaction.

## Appendix: Era mainnet configuration

The configuration below is derived from all 26,575 priority operations of ZKsync Era (chain 324)
between 2025-11-06 and 2026-11-09 (L1 blocks 23,740,000 to 26,376,900). With it and every cap at
`type(uint256).max`, all of them pass in `ALLOW_ALL` mode.

### Legacy bridges

`setLegacyBridge` for the Lido wstETH L1 bridge `0x41527b2d03844db6b0945f25702cb958b6d55989`, the
only custom bridge that uses the legacy `finalizeDeposit` encoding.

### Withdrawal functions

On top of the built-ins:

| L2 contract                                 | Address                                      | Function                                         |
| ------------------------------------------- | -------------------------------------------- | ------------------------------------------------ |
| Legacy L2 shared bridge                     | `0x11f943b2c77b743ab90f4a0ae7d5a4e7fca3e102` | `withdraw(address,address,uint256)` `0xd9caed12` |
| L2 WETH                                     | `0x5aea5775959fbc2557cc8789bc1bf90a239d9a91` | `withdraw(uint256)` `0x2e1a7d4d`                 |
| ZK                                          | `0x5a7d6b2f92c77fad6ccabd7ee0624e64907eaf3e` | `approve(address,uint256)` `0x095ea7b3`          |
| Lido L2 bridge                              | `0xe1d6a50e7101c8f8db77352897ee3f1ac53f782b` | `withdraw(address,address,uint256)` `0xd9caed12` |
| NODL L2 bridge                              | `0x2c1b65da72d5cf19b41de6edccfb7dd83d1b529e` | `withdraw(address,uint256)` `0xf3fef3a3`         |
| NODL (burned by its bridge with `burnFrom`) | `0xbd4372e44c5ee654dd838304006e1f0f69983154` | `approve(address,uint256)` `0x095ea7b3`          |

### Tokens

The base token (ETH, asset id `0x05e1c3ae4b9732444ae25217ac7666e46fa365fee1768de00c9fcb65532b7609`)
is set by `initialize`. `setDepositCaps` covers the 70 tokens listed below: the 49 deposited
through the L1 asset router in that period and 21 more that were only withdrawn from Era in it.

- Their handler is the native token vault, and each asset id is the one returned by
  `L1NativeTokenVault.assetId(token)`. For a token native to L1, the filterer derives the same id
  from a legacy-encoded deposit. A token native to Era (ZK in this list) uses the new encoding, and
  its id is not the one derived from its L1 token address.
- The list is a floor, not the whitelist: a token with a supply on Era that was not bridged in
  that period is rejected unless it is added too. The whitelist is built from all tokens bridged
  to Era before the filterer is set.

<details>
<summary>Tokens bridged between Era and L1, 2025-11-06 to 2026-11-09</summary>

| Token                                         | L1 token                                     | Asset id                                                             | Bridged        |
| --------------------------------------------- | -------------------------------------------- | -------------------------------------------------------------------- | -------------- |
| USD Coin (USDC)                               | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | `0x79272c08dbfbb367e07f7607be00657ae4a9c15ba0b08b12aa00fb77a0a4aa83` | deposited      |
| Tether USD (USDT)                             | `0xdac17f958d2ee523a2206206994597c13d831ec7` | `0xdde1b8f84d54bbaba65c196655baa8458cbb20c0d62f6b8ae4ff5e801456e6bd` | deposited      |
| DEXTF Token (DEXTF)                           | `0x5f64ab1544d28732f0a24f4713c2c8ec0da089f0` | `0xf77081fe8d7197d30644ed6bf1973b18db582d693b8f393ed4a1f97b07999075` | deposited      |
| ZKsync (ZK)                                   | `0x66a5cfb2e9c529f14fe6364ad1075df3a649c0a5` | `0x83e2fbc0a739b3c765de4c2b4bf8072a71ea8fbb09c8cf579c71425d8bc8804a` | deposited      |
| StorjToken (STORJ)                            | `0xb64ef51c888972c908cfacf59b47c1afbc0ab8ac` | `0xadc1f48e87dab1d14ea9cceec7f282db23eeef531595895113d19b07a3edeae7` | deposited      |
| SolarCoin on Mainnet (SLR)                    | `0x4e9e4ab99cfc14b852f552f5fb3aa68617825b6c` | `0x121b43826b62840d917204bf98e4e0fa89e4b700731216fe163b4b23d0458f77` | deposited      |
| Mute.io (MUTE)                                | `0xa49d7499271ae71cd8ab9ac515e6694c755d400c` | `0xaf79c19114b1c9ac2b91ead7755b69386052d5733dc649777d3123b1501f939b` | deposited      |
| Wrapped liquid staked Ether 2.0 (wstETH)      | `0x7f39c581f595b53c5cb19bd0b3f8da6c935e2ca0` | `0x02d11e71607cfc979e8008cd84f86d1fd9065f8b24dd5e18216eca6e3a4f679b` | deposited      |
| HarryPotterObamaSonic10Inu (BITCOIN)          | `0x72e4f9f808c49a2a61de9c5896298920dc4eeea9` | `0x7b98b5ac4cd572cfbd7f44dd90d6b611c0ba888ea584762ca0de760aad190666` | deposited      |
| GOVI (GOVI)                                   | `0xeeaa40b28a2d1b0b08f6f97bb1dd4b75316c6107` | `0x3c8f585472b6576a2e8bbc038728a59ca390afbfaaf4a60d0564729ee6a09d13` | deposited      |
| Symbiosis (SIS)                               | `0xd38bb40815d2b0c2d2c866e0c72c5728ffc76dd9` | `0xd5b6dba6dbc8f1af64ffc8226a738dc9f58892cc896a009ef1d465bbcabc1d88` | deposited      |
| Pepe (PEPE)                                   | `0x6982508145454ce325ddbe47a25d4ec3d2311933` | `0x80bca8b67fda37db07ee905c8084070559062dc259297b69134f3609e9a18e29` | deposited      |
| TRALA TOKEN (TRALA)                           | `0xd5e0eda0214f1d05af466e483d9376a77a67448b` | `0x79cfaca69a3b98d6f05a60c1d697375c7678a27446a5c41f76c8d951c0efbda9` | deposited      |
| ZKBase (ZKB)                                  | `0xbbbbbbbb46a1da0f0c3f64522c275baa4c332636` | `0x7c6b8daa35096ad49ccd983b305c1e9732f033c23216c3f438f132351ce1bcf8` | deposited      |
| Wrapped SOL (SOL)                             | `0xd31a59c85ae9d8edefec411d448f90841571b89c` | `0xf935c282cbec7474b73df0da74f4fc5e68f6b6f87642bee3164c017bb818a7ca` | deposited      |
| Heurist (HEU)                                 | `0xec463d00aa4da76fb112cd2e4ac1c6bef02da6ea` | `0xe5b8088df902a717664afd89b1db2f2791453765a01898d58e91d4c7ced22c0c` | deposited      |
| Impermax (IBEX)                               | `0xf655c8567e0f213e6c634cd2a68d992152161dc6` | `0x1f6c5a59546853722ec72235378af398f295407cee936a4849c791eebaaeb13e` | deposited      |
| DeversiFi Token (DVF)                         | `0xdddddd4301a082e62e84e43f474f044423921918` | `0x47fbbc284ee90d6b3b049c5f2470a185660b6d29739a28439dfb5afae1a1c512` | deposited      |
| Gravita Debt Token (GRAI)                     | `0x15f74458ae0bfdaa1a96ca1aa779d715cc1eefe4` | `0xf340e367252a9022b7ac14bebaef4885ed6ff4a21d44c0f99294bea09528870a` | deposited      |
| rsETH (rsETH)                                 | `0xa1290d69c65a6fe4df752f95823fae25cb99e5a7` | `0xa23b2a38addf1a24f9d8883cabecfe2ea6634f25946723453e0af9b7d2dcd2b2` | deposited      |
| UniDex (UNIDX)                                | `0x95b3497bbcccc46a8f45f5cf54b0878b39f8d96c` | `0xb3ab329a38fd582c919601bcbfc25ea00077eaff8863b16074a4e12f36b0e143` | deposited      |
| Syncus (SYNC)                                 | `0xa41d2f8ee4f47d3b860a149765a7df8c3287b7f0` | `0xdbd8961e3500f6e743948df2b11c21d4bed0b28714dd35870ea51536c11b40c9` | deposited      |
| FLOKI (FLOKI)                                 | `0xcf0c122c6b73ff809c693db761e7baebe62b6a2e` | `0x0614d4a82aab9c6ebd136b569e40b56643dadb9c83100b61ef5ba50f7d131349` | deposited      |
| Staked Trala Token (sTrala)                   | `0xffa9828cfe71ea561e0db2e2f03899567196af78` | `0xff95ef03857c8f2e0759150bc40fb3fb9875a2cf0c209c8cb60759fce9e397e3` | deposited      |
| Balancer (BAL)                                | `0xba100000625a3754423978a60c9317c58a424e3d` | `0x8c671d176b6084bc5b57141439f74b0839b0964de11afe7674a82b4c2e44359c` | deposited      |
| Perpetual (PERP)                              | `0xbc396689893d065f41bc2c6ecbee5e0085233447` | `0xf51f80bf5c204b6b05e96772df101c57a561c19d3e83778027a9776c1c48aff4` | deposited      |
| ether.fi governance token (ETHFI)             | `0xfe0c30065b384f05761f15d0cc899d4f9f9cc0eb` | `0xf434b65363fac82e8e5f607a97d5718da59d57cce5a7e20d8ba022d2be7008bc` | deposited      |
| Immutable X (IMX)                             | `0xf57e7e7c23978c3caec3c3548e3d615c346e79ff` | `0x49d45229eef8b5fd7119c15a79d4fa072cf69c337bf61e1ba6e33886ec48c856` | deposited      |
| izumi Token (iZi)                             | `0x9ad37205d608b8b219e6a2573f922094cec5c200` | `0x61a597cf4656a31a630b89e91e0da619a8393e10cbabc7404413761c1f80e950` | deposited      |
| SHIBA INU (SHIB)                              | `0x95ad61b0a150d79219dcf64e1e6cc01f0b64c4ce` | `0x89a9e2aa8e84159232f9c9d5cf45b151450d6a40b2a0e91fa5416ca8acc01efb` | deposited      |
| HYCO (HYCO)                                   | `0x77f76483399dc6328456105b1db23e2aca455bf9` | `0xe01e29c16aacc4685bc788adbe6d709584cfe76b39e6d8f639d85ce6d0d4485d` | deposited      |
| ChainLink Token (LINK)                        | `0x514910771af9ca656af840dff83e8264ecf986ca` | `0xc7357b06641cc5c362187d288e23e0338fa823487366bba5d50a8905b192841a` | deposited      |
| LSD Coin (LSD)                                | `0xfac77a24e52b463ba9857d6b758ba41ae20e31ff` | `0x4a4953f9103e69a0c563ff45a6b5ee5152e1a59bcf31cc2093b41114335b6397` | deposited      |
| MetaMask USD (mUSD)                           | `0xaca92e438df0b2401ff60da7e4337b687a2435da` | `0x5a4123bf17a9b05c0216c187ae068768de1613124370bfc7ef63287dc812319a` | deposited      |
| LUSD Stablecoin (LUSD)                        | `0x5f98805a4e8be255a32880fdec7f6728c6568ba0` | `0xca4d2589700d528ad7316c573629d41a667c4f852d661d39abf18f8e15b6e0a2` | deposited      |
| Euro Coin (EURC)                              | `0x1abaea1f7c830bd89acc67ec4af516284b1bc33c` | `0x6b7c4c53ae9189e377903b3a9881ebd43767f08249b4d77a2237283dff41d8cb` | deposited      |
| WHALEZ (WHALEZ)                               | `0x76054592d1f789ea5958971fb3ba6628334faa86` | `0xb56b80818e18bbf0d2f911397564393acc5e79e46a7870807c6d1690f586028e` | deposited      |
| Zks (ZKS)                                     | `0xe4815ae53b124e7263f08dcdbbb757d41ed658c6` | `0x197e50e7e36ea721da6b7aaab4f310e0d35bc4028ad4e913f152426a606d13c8` | deposited      |
| FUL (FUL)                                     | `0x4eb8a4015a67975a23adc80aa50d2d996986f43d` | `0x55cd8972396c6b378fc60e23a1c8d4cc7ef2d16c4140f3c108e9df48de379df7` | deposited      |
| Wren Staked tGBP (wstGBP)                     | `0x57c3571f10767e49c9d7b60feb6c67804783b7ae` | `0xb28a5effd0530e6e9a9c0f94534942a222e6945da6ac9414d6debd4a1d34f9f8` | deposited      |
| Idexo Token (IDO)                             | `0xf9c53268e9de692ae1b2ea5216e24e1c3ad7cb1e` | `0xf889baf6cc0f47b82f4121fe51619cfa013123383f3a196c93c4a33ed8ba8fc5` | deposited      |
| Milady Cult Coin (CULT)                       | `0x0000000000c5dc95539589fbd24be07c6c14eca4` | `0x9feaf3342652d679e3b0e86b1b4be6ee9ab1ce0edd8080310e29cfb65ca0ef4b` | deposited      |
| Uds My (UDS)                                  | `0x2162fdb116bc95d85b898bdae77e053ef0c36eaa` | `0x7f1c8a59ac85df4e0d65988a82901900b6f98036463d12a4bd206f4cd8d3eea9` | deposited      |
| The Infinite Garden (ETH)                     | `0x5e21d1ee5cf0077b314c381720273ae82378d613` | `0x4eb25013e72dad53b978a1318b845e61794474742209d9142684053228954efd` | deposited      |
| Dai Stablecoin (DAI)                          | `0x6b175474e89094c44da98b954eedeac495271d0f` | `0x28d79ad6f1eceadaec9fa58f9ab505ada95eecf66d29bc404034e9646efd3a84` | deposited      |
| Wrapped TON Coin (TONCOIN)                    | `0x582d872a1b094fc48f5de31d3b73f2d9be47def1` | `0xcbe23b433a3b77bbac62efe88310348323852f5587f3a5d078beab74d8a008d2` | deposited      |
| syBTC (syBTC)                                 | `0x01a8b61e7b03891a736b5df865e0ef9c511850ad` | `0x1cf7a46bd8ad6ef17ea2f746958d0980cc5ddfd30d4d95c69e2ff0e6ba7cdbfc` | deposited      |
| Wrapped BTC (WBTC)                            | `0x2260fac5e5542a773aa44fbcfedf7c193bc2c599` | `0x42da3783e03694dbfb1491ffc872529ecc3964e8231f87e0a04be359d1451e60` | deposited      |
| Polygon from Ethereum from PulseChain (MATIC) | `0x47b40ae790214886f847bc279f9b5b3b4e31e702` | `0x22ef3b5dc08b7f343d2c7491b9ca410203b616f380802ce85ec779b31958ed31` | deposited      |
| Rocket Pool ETH (rETH)                        | `0xae78736cd615f374d3085123a210448e74fc6393` | `0xbd15221d36dfce929a8f6f8e74436f270b5a1fd59d08e824b26d106fd684bff7` | withdrawn only |
| Coinbase Wrapped Staked ETH (cbETH)           | `0xbe9895146f7af43049ca1c1ae358b0541ea49704` | `0xed60ca3692166cef7126eb3ea525e2024b79be272853e8c6901b29f4c3b4125d` | withdrawn only |
| 1INCH Token (1INCH)                           | `0x111111111117dc0aa78b770fa6a738034120c302` | `0xf15a45b7fa0532768a43b8ab85406dd8622d362df66bddd8437343884a65f0e6` | withdrawn only |
| SINERGIA (SNG)                                | `0xcfd6ae8bf13f42de14867351eaff7a8a3b9fbbe7` | `0x35c904de27493e5f9e5a7380155d5f885ae9045536660537cc76a3d36a49c3a3` | withdrawn only |
| Wrapped Ether (WETH)                          | `0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2` | `0x80e5f7ee801b3f4eee9850a57443d1fbaeec0ddd2d4777dd1aa1c1f44766afbd` | withdrawn only |
| Koi (KOI)                                     | `0x9d14bce1daddf408d77295bb1be9b343814f44de` | `0xb205975c3a37149fb492f4631604d35a01e515f72c1d93d814d7bc433af5ae00` | withdrawn only |
| TiTi (TiTi)                                   | `0x3bdffa70f4b4e6985eed50453c7c0d4a15dcec52` | `0x38cf50924a29b67e838785e3d188831d712d4688e595af20f93a19ef85271af9` | withdrawn only |
| Tellor Tributes (TRB)                         | `0x88df592f8eb5d7bd38bfef7deb0fbc02cf3778a0` | `0xa3b6726814fd1c07c4c368bc7c5e93a79adb440a7f6c8949811edf77fd41a8b7` | withdrawn only |
| Bella (BEL)                                   | `0xa91ac63d040deb1b7a5e4d4134ad23eb0ba07e14` | `0xb7364e7b534479a07b23f03410f622b0a0eb27017ff5d7cf389b2288859510ed` | withdrawn only |
| Curve.Fi USD Stablecoin (crvUSD)              | `0xf939e0a03fb07f59a73314e73794be0e57ac1b4e` | `0x8b326eb0bc1dd070460818d94e2022b579ba869e9751b321f8e46cff289ab62d` | withdrawn only |
| ZigZag (ZZ)                                   | `0xc91a71a1ffa3d8b22ba615ba1b9c01b2bbbf55ad` | `0x9ef4d5e89e302dd80060d3f77a984dba907d26b97103475084120ccfad7e98bd` | withdrawn only |
| Loiyaa (LYAA)                                 | `0xe2e252cd7b04449eb516975d02d5ac23a14b5064` | `0x63d607970db13befa8fd6c780a88c36d8ea34f7fb86cf97c7507048c1c57f684` | withdrawn only |
| XRAISE TOKEN (RAISE)                          | `0xa69da8ae31b6de5082aa6e8aa3b1c01ecb0b3d37` | `0xd5efc06007a09e15b5a7366959ffa7ec1aec4d95c2b7b9fa51fb0df445586946` | withdrawn only |
| wTBT Pool (wTBT)                              | `0xd38e031f4529a07996aab977d2b79f0e00656c56` | `0x8f4c0fa43c0abfd61939017bc491adb4f3cf77124678a8fa54cf5248f0c9c360` | withdrawn only |
| DOX Coin (DOX)                                | `0x93728f9b63edbb91739f4fbaa84890e5073e3d4f` | `0x18c6deb2a0834e039bdcc63b52ddd593fa97736efcc66667398a344eac35a31e` | withdrawn only |
| tipcoin (TIP)                                 | `0x64f80550848eff3402c5880851b77dd82a1a71f3` | `0x0327fa0959788ecc989b2fbcb8d46e0b3b6696608eeff8203ae2179783515793` | withdrawn only |
| 0xAgentsAI (AGENT)                            | `0xd514b77060e04b1ee7e15f6e1d3b5419e9f32773` | `0xce630b39cf8901f920916877140882330fd1e2461ae40c10c5f9225ca1a625ee` | withdrawn only |
| Synth sXRP (sXRP)                             | `0xa2b0fde6d710e201d0d608e924a484d1a5fed57c` | `0xc7dd37262af7c922fe6d74d9479db2fd6ecb5d45afca2a2ea603169f31285299` | withdrawn only |
| Beam (BEAM)                                   | `0x62d0a8458ed7719fdaf978fe5929c6d342b0bfce` | `0x5f6b4d1bc23150a6e6deff2b861ebbbfe17bc20f0d72e342e041509156d4d616` | withdrawn only |
| Aave Token (AAVE)                             | `0x7fc66500c84a76ad7e9c93437bfc5ac33e2ddae9` | `0xbcb84c2ecd828786f4c886d20557d65775c6f44e594b66268d91e6a843fbd8de` | withdrawn only |
| Uniswap (UNI)                                 | `0x1f9840a85d5af5bf1d1762f925bdaddc4201f984` | `0x722544b6bfa1099fcfc55b6c44d01ad4e6960376fd5d37e44145bdaba6a3ccb7` | withdrawn only |

</details>

### Exemption candidates

In `WITHDRAWALS_ONLY` mode the messages of these senders are generic calls, so they are rejected
unless the sender is exempt. The `ProtocolUpgradeHandler` is exempted from the start (see
[Setup](#setup)). Exempting the others is a policy decision; the last column shows who can make
each of them send.

| Sender                                   | Address                                      | Transactions | Sends                                                                                      | Who triggers it                                                                                              |
| ---------------------------------------- | -------------------------------------------- | ------------ | ------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------ |
| Across `HubPool`                         | `0xc186fa914353c44b2e33ebe05f21846f1048beda` | 14,004       | root bundles and ETH to its L2 `SpokePool`, and 18 token deposits through the asset router | anyone, for a root bundle that passed its challenge period; its owner, with any message                      |
| Chainlink `ZKSyncValidator`              | `0xdd2e524d186615dedd052c35d3f669b35c5faa8c` | 462          | L2 sequencer uptime feed updates                                                           | accounts on its access list                                                                                  |
| Rocket Pool `RocketZkSyncPriceMessenger` | `0x6cf6cb29754aebf88af12089224429bd68b0b8c8` | 367          | rETH rate updates                                                                          | anyone; the caller chooses the gas limit and gets the L2 refund, an uncapped ETH deposit: not to be exempted |
| zkLink `ZkSyncL1Gateway`                 | `0xecd189e0f390826e137496a4e4a23acf76c942ab` | 301          | messages to its L2 gateway                                                                 | its arbitrator; its relayers retry a failed message with any `mintValue` and refund recipient                |
| Across `AtomicWethDepositor`             | `0x64668fbd18b967b46dd22dc8675134d91efedd8d` | 29           | ETH to an L2 account                                                                       | anyone, with any Bridgehub request: not to be exempted                                                       |
| Aave a.DI `CrossChainController`         | `0xed42a7d8559a463722ca4bed50e0cc05a386b0e1` | 4            | governance messages                                                                        | approved senders; retries by its owner or guardian                                                           |
| ZKsync `ProtocolUpgradeHandler`          | `0xe30dca3047b37dc7d88849de4a4dc07937ad5ab3` | 1            | L2 contract upgrades                                                                       | governance                                                                                                   |
| L2Scan `L2ScanEthereumBridgeV2`          | `0x375424756f4a5ada1ce1e0849abdd19255b1729e` | 1            | ETH to an L2 account                                                                       | anyone, with any L2 call: not to be exempted                                                                 |
| Unverified contract                      | `0xab23df3fd78f45e54466d08926c3a886211ac5a1` | 2            | `receiveHashes` calls to two L2 contracts                                                  | unknown: not to be exempted while unverified                                                                 |

Apart from the asset router and the Lido and NODL bridges, the other senders were EOAs and two
Safes, mostly sending ETH, which `WITHDRAWALS_ONLY` mode is meant to reject.

### NODL

NODL is a known misfit. The NODL bridge (L1 `0x2d02b651ea9630351719c8c55210e042e940d69a`, L2
`0x2c1b65da72d5cf19b41de6edccfb7dd83d1b529e`) delivers deposits with
`finalizeDeposit(address,address,uint256)` (`0x4ddf75e6`), not the legacy encoding.

- Registering it with `setLegacyBridge` has no effect, so its deposits are generic calls. In
  `ALLOW_ALL` mode they pass with no token cap. In `WITHDRAWALS_ONLY` mode they are rejected unless
  the bridge is exempt, and an exemption lets them through uncapped.
- A rejection reverts the whole L1 deposit, so no NODL is lost. NODL is native to Era and its
  bridge burns it on one side and mints it on the other, so no L1 escrow is exposed. Its
  withdrawals fit.
- The period has 7 NODL deposits, the largest of 450,000 NODL. Capping them would need the
  filterer to decode per-bridge deposit encodings.
