use alloy::sol;

use crate::upgrade_verification::verifiers::{VerificationResult, Verifiers};

sol! {
    // v31: the chain-creation diamond cut's initCalldata is abi.encode(InitializeDataNewChain)
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
    pub fn verify(&self, verifiers: &Verifiers, result: &mut VerificationResult) {
        result.expect_zk_bytecode(verifiers, &self.l2BootloaderBytecodeHash, "Bootloader");
        result.expect_zk_bytecode(
            verifiers,
            &self.l2DefaultAccountBytecodeHash,
            "system-contracts/DefaultAccount",
        );
        result.expect_zk_bytecode(verifiers, &self.l2EvmEmulatorBytecodeHash, "EvmEmulator");
    }
}
