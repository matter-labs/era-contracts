use std::fmt::Display;

use alloy::{primitives::U256, sol};

use crate::upgrade_verification::verifiers::{VerificationResult, Verifiers};

use super::super::MAX_PRIORITY_TX_GAS_LIMIT;

sol! {
    #[derive(Debug, Default, PartialEq, Eq)]
    enum PubdataPricingMode {
        #[default]
        Rollup,
        Validium
    }

    #[derive(Debug, Default, PartialEq, Eq)]
    struct FeeParams {
        PubdataPricingMode pubdataPricingMode;
        uint32 batchOverheadL1Gas;
        uint32 maxPubdataPerBatch;
        uint32 maxL2GasPerBatch;
        uint32 priorityTxMaxPubdata;
        uint64 minimalL2GasPrice;
    }

    struct VerifierParams {
        bytes32 recursionNodeLevelVkHash;
        bytes32 recursionLeafLevelVkHash;
        bytes32 recursionCircuitsSetVksHash;
    }

    struct InitializeDataNewChain {
        address verifier;
        VerifierParams verifierParams;
        bytes32 l2BootloaderBytecodeHash;
        bytes32 l2DefaultAccountBytecodeHash;
        bytes32 l2EvmEmulatorBytecodeHash;
        uint256 priorityTxMaxGasLimit;
        FeeParams feeParams;
        address blobVersionedHashRetriever;
    }
}

impl InitializeDataNewChain {
    pub async fn verify(
        &self,
        verifiers: &Verifiers,
        result: &mut VerificationResult,
        is_gateway: bool,
    ) -> anyhow::Result<()> {
        result.print_info("== checking initialize data ===");

        let name = if is_gateway {
            "gateway_verifier_addr"
        } else {
            "verifier"
        };

        result.expect_address(verifiers, &self.verifier, name);
        if self.verifierParams.recursionNodeLevelVkHash != [0u8; 32]
            || self.verifierParams.recursionLeafLevelVkHash != [0u8; 32]
            || self.verifierParams.recursionCircuitsSetVksHash != [0u8; 32]
        {
            result.report_error("Verifier params must be empty.");
        }

        result.expect_zk_bytecode(verifiers, &self.l2BootloaderBytecodeHash, "Bootloader");
        result.expect_zk_bytecode(
            verifiers,
            &self.l2DefaultAccountBytecodeHash,
            "system-contracts/DefaultAccount",
        );
        result.expect_zk_bytecode(verifiers, &self.l2EvmEmulatorBytecodeHash, "EvmEmulator");

        if self.priorityTxMaxGasLimit != U256::from(MAX_PRIORITY_TX_GAS_LIMIT) {
            result.report_warn(&format!(
                "priorityTxMaxGasLimit must be 72_000_000 got {}",
                self.priorityTxMaxGasLimit
            ));
        }

        if self.feeParams != verifiers.fee_param_verifier.fee_params {
            result.report_error(&format!(
                "Incorrect fee params. Expected: {:#?}\nReceived: {:#?}",
                verifiers.fee_param_verifier.fee_params, self.feeParams
            ));
        } else {
            result.report_ok("Fee params are correct");
        }
        Ok(())
    }
}

impl Display for PubdataPricingMode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PubdataPricingMode::Rollup => write!(f, "Rollup"),
            PubdataPricingMode::Validium => write!(f, "Validium"),
            PubdataPricingMode::__Invalid => write!(f, "Invalid"),
        }
    }
}
