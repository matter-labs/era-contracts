# Known issues
- L2SharedBridge will be a system contract, L2NativeTokenVault will replace it ( the storage layout is still not yet backwards compatible)
- _parseL2WithdrawalMessage in L1SharedBridge is not yet backwards compatible
- Deposits will stop working during the upgrade, as the contracts are not backwards compatible with the legacy versions of each other. In particular, the L1SharedBridge, Mailbox and Bridgehub.  
- We will manually finalize all legacy withdrawals before the ugprade, i.e. withdrawals that happened before the previous Bridghub upgrade.