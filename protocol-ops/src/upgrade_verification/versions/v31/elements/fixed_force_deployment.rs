use alloy::{
    primitives::{Address, U256},
    sol,
};

use crate::upgrade_verification::verifiers::{VerificationResult, Verifiers};

use super::super::MAX_NUMBER_OF_ZK_CHAINS;

sol! {
    #[derive(Debug)]
    struct FixedForceDeploymentsData {
        uint256 l1ChainId;
        uint256 eraChainId;
        address l1AssetRouter;
        bytes32 l2TokenProxyBytecodeHash;
        address aliasedL1Governance;
        uint256 maxNumberOfZKChains;
        bytes32 bridgehubBytecodeHash;
        bytes32 l2AssetRouterBytecodeHash;
        bytes32 l2NtvBytecodeHash;
        bytes32 messageRootBytecodeHash;
        address l2SharedBridgeLegacyImpl;
        address l2BridgedStandardERC20Impl;
        // The forced beacon address. It is needed only for internal testing.
        // MUST be equal to 0 in production.
        // It will be the job of the governance to ensure that this value is set correctly.
        address dangerousTestOnlyForcedBeacon;
    }
}

impl FixedForceDeploymentsData {
    pub async fn verify(
        &self,
        verifiers: &Verifiers,
        result: &mut VerificationResult,
    ) -> anyhow::Result<()> {
        let expected_l1_chain_id = verifiers.network_verifier.get_l1_chain_id();
        if U256::from(expected_l1_chain_id) != self.l1ChainId {
            result.report_error(&format!(
                "L1 chain id mismatch: expected {}, got {}",
                expected_l1_chain_id, self.l1ChainId,
            ));
        }

        let era_chain_id = verifiers.network_verifier.get_era_chain_id();
        if U256::from(era_chain_id) != self.eraChainId {
            result.report_error(&format!(
                "Era chain id mismatch: expected {}, got {}",
                era_chain_id, self.eraChainId
            ));
        }

        result.expect_address(verifiers, &self.l1AssetRouter, "l1_asset_router_proxy");
        result.expect_zk_bytecode(
            verifiers,
            &self.l2TokenProxyBytecodeHash,
            "l1-contracts/BeaconProxy",
        );
        result.expect_address(
            verifiers,
            &self.aliasedL1Governance,
            "aliased_protocol_upgrade_handler_proxy",
        );

        if self.maxNumberOfZKChains != U256::from(MAX_NUMBER_OF_ZK_CHAINS) {
            result.report_error("maxNumberOfZKChains must be 100");
        }

        result.expect_zk_bytecode(
            verifiers,
            &self.bridgehubBytecodeHash,
            "l1-contracts/Bridgehub",
        );
        result.expect_zk_bytecode(
            verifiers,
            &self.l2AssetRouterBytecodeHash,
            "l1-contracts/L2AssetRouter",
        );
        result.expect_zk_bytecode(
            verifiers,
            &self.l2NtvBytecodeHash,
            "l1-contracts/L2NativeTokenVault",
        );

        result.expect_zk_bytecode(
            verifiers,
            &self.messageRootBytecodeHash,
            "l1-contracts/MessageRoot",
        );

        result.expect_address(verifiers, &self.l2SharedBridgeLegacyImpl, "zero");

        result.expect_address(verifiers, &self.l2BridgedStandardERC20Impl, "zero");

        if self.dangerousTestOnlyForcedBeacon != Address::ZERO {
            result.report_error("dangerousTestOnlyForcedBeacon must be 0");
        }

        Ok(())
    }
}
