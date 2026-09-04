use alloy::{primitives::FixedBytes, sol};

use crate::upgrade_verification::{
    artifacts::CtmFlavor,
    verifiers::{VerificationResult, Verifiers},
};

sol! {
    // v33: the chain-creation diamond cut's initCalldata is abi.encode(InitializeDataNewChain)
    // — just the three bytecode hashes. ChainTypeManagerBase prepends the selector and all
    // per-chain fields (chainId, admin, bridgehub, …) at chain-creation time.
    // The verifier is fetched from CTM.protocolVersionVerifier() inside DiamondInit; fee params
    // are hardcoded from Config.sol constants — neither appears in initCalldata.
    #[derive(Debug, Default, PartialEq, Eq)]
    struct InitializeDataNewChain {
        bytes32 l2BootloaderBytecodeHash;
        bytes32 l2DefaultAccountBytecodeHash;
        bytes32 l2EvmEmulatorBytecodeHash;
    }
}

impl InitializeDataNewChain {
    /// Verify the three bytecode hashes per CTM flavor:
    ///
    /// - **Era** chains pass all three through `DiamondInit.initialize`'s
    ///   non-zero guard (see `DiamondInit.sol:70-82`) and into the chain
    ///   storage, so each must map to its expected ZK bytecode file.
    /// - **ZKsync OS** chains skip that guard and never read these fields —
    ///   `ChainCreationParamsLib.getChainCreationParams` leaves them at
    ///   `bytes32(0)`. Anything non-zero here would indicate the wrong
    ///   chain-creation params were wired into a ZKsync OS CTM.
    pub fn verify(
        &self,
        flavor: CtmFlavor,
        verifiers: &Verifiers,
        result: &mut VerificationResult,
    ) {
        match flavor {
            CtmFlavor::Era => {
                result.expect_zk_bytecode(verifiers, &self.l2BootloaderBytecodeHash, "Bootloader");
                result.expect_zk_bytecode(
                    verifiers,
                    &self.l2DefaultAccountBytecodeHash,
                    "system-contracts/DefaultAccount",
                );
                result.expect_zk_bytecode(
                    verifiers,
                    &self.l2EvmEmulatorBytecodeHash,
                    "EvmEmulator",
                );
            }
            CtmFlavor::ZksyncOs => {
                self.expect_zero(
                    "l2BootloaderBytecodeHash",
                    &self.l2BootloaderBytecodeHash,
                    result,
                );
                self.expect_zero(
                    "l2DefaultAccountBytecodeHash",
                    &self.l2DefaultAccountBytecodeHash,
                    result,
                );
                self.expect_zero(
                    "l2EvmEmulatorBytecodeHash",
                    &self.l2EvmEmulatorBytecodeHash,
                    result,
                );
            }
        }
    }

    fn expect_zero(&self, field: &str, value: &FixedBytes<32>, result: &mut VerificationResult) {
        if *value == FixedBytes::<32>::ZERO {
            result.report_ok(&format!(
                "InitializeDataNewChain.{field} is zero (expected for ZKsync OS CTM)"
            ));
        } else {
            result.report_error(&format!(
                "InitializeDataNewChain.{field} must be zero for ZKsync OS CTM, got {value}"
            ));
        }
    }
}
