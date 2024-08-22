# Contracts Review Preparation

## High-level Overview

### Reason for changes

The goal was to be build a foundation to be able to support token bridging with custom logic on receiving chain (not wrapped), as well as custom bridging logic (assets, which accrue value over time, like LRTs).
For clarity, we only developed a framework, the exact logic for custom tokens and custom bridging will follow.

### Major changes

In order to achieve it, we separated the liquidity managing logic from the Shared Bridge to `Asset Handlers`. The basic cases will be handled by `Native Token Vaults`, which are handling all of the standard `ERC20 tokens`, as well as `ETH`.

### New concepts

- assetHandler => contract that manages liquidity (burns/mints, locks/unlocks) for specific token (or a set of them)
- assetId => identifier to track bridged assets across chains linked to specific asset handler

## Known Issues

### storage layout

L2SharedBridge will be a system contract, L2NativeTokenVault will replace it (the storage layout is still not yet backwards compatible)

### bridgehubDeposit API change

> /// @notice Allows bridgehub to acquire mintValue for L1->L2 transactions.

    /// @dev If the corresponding L2 transaction fails, refunds are issued to a refund recipient on L2.
    function bridgehubDepositBaseToken(
        uint256 _chainId,
        bytes32 _assetId,

Note, that the new SB is not compatible with both:

- old Mailbox on Era
- old Bridgehub
- And vice versa.

We need to either:

- ensure that all 3 get upgraded at the same time. Upgrading BH and SB at the same time is feasible IMHO. But upgrading DP (Mailbox) in the same transaction may not be.
- have a concrete plan for such case. E.g. explicitly tell that the legacy deposits will stop working. In this case we need to check (at the very least visually) that the worst thing that can happen is just deposits not working and not some funds lost
- Add the corresponding legacy functions
  This text you see here is \*actually- written in Markdown! To get a feel
  for Markdown's syntax, type some text into the left window and
  watch the results in the right.

### not allowing legacy withdrawals

> require(!\_isEraLegacyEthWithdrawal(\_chainId, \_l2BatchNumber), "ShB: legacy eth withdrawal");

No method to finalize an old withdrawal.
We will manually finalize all legacy withdrawals before the upgrade, i.e. withdrawals that happened before the previous Bridgehub upgrade.

### Custom Errors not implemented

> require(expectedDepositAmount == \_depositAmount, "3T"); // The token has non-standard transfer logic

Custom errors will be introduced for all contracts.

## Migration plan

- Bulkheads will need to be migrated (methods added)
- Tokens will have to be transferred (methods added)
