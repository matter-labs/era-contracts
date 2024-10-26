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

### Not allowing legacy withdrawals

> require(!\_isEraLegacyEthWithdrawal(\_chainId, \_l2BatchNumber), "ShB: legacy eth withdrawal");

No method to finalize an old withdrawal.
We will manually finalize all legacy withdrawals before the upgrade, i.e. withdrawals that happened before the previous Bridgehub upgrade.

### Custom Errors not implemented

> require(expectedDepositAmount == \_depositAmount, "3T"); // The token has non-standard transfer logic

Custom errors will be introduced for all contracts.

## Migration plan

- Bulkheads will need to be migrated (methods added)
- Tokens will have to be transferred (methods added)
