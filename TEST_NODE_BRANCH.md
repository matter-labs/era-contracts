This branch is used by the era-test-node repo.

The next changes were introduced:
- [bootloader.yul](system-contracts/bootloader/bootloader.yul)
  - Debug data, marked as `DEBUG SUPPORT` blocks.
  - Impersonating preprocessing mode, blocks `<!-- @ifdef ACCOUNT_IMPERSONATING -->` and at some places added `<!-- @ifndef ACCOUNT_IMPERSONATING -->` condition.
- [preprocess-bootloader.ts](system-contracts/scripts/preprocess-bootloader.ts)
  - Impersonating preprocessing mode, "For impersonating" blocks.
- [DefaultAccount.sol](system-contracts/contracts/DefaultAccount.sol)
  - Return transaction data (empty), marked as `FOUNDRY SUPPORT` blocks.
- [DefaultAccountNoSecurity.sol](system-contracts/contracts/DefaultAccountNoSecurity.sol)
  - NEW smart contract, only for Hardhat/Forge testing.
- [IAccount.sol](system-contracts/contracts/interfaces/IAccount.sol)
  - Return transaction data (empty), marked as `FOUNDRY SUPPORT` blocks.
