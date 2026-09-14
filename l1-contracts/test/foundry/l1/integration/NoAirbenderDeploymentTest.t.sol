// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {L2TxMocker} from "./_SharedL2TxMocker.t.sol";

import {IEraMultiProofVerifier} from "contracts/state-transition/chain-interfaces/IEraMultiProofVerifier.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {AIRBENDER_PROOF_SYSTEM_DISABLED} from "contracts/common/Config.sol";

/// @notice Deploys the ecosystem with `airbender_verifier = false`, the configuration the production
/// template used to default to.
/// @dev Without this suite nothing exercised that path: the chain's verifier is the bare Boojum router,
/// which reads a single public input, so a chain created still requiring the Airbender lane could neither
/// commit nor prove.
contract NoAirbenderDeploymentTest is L1ContractDeployer, ZKChainDeployer, TokenDeployer, L2TxMocker {
    function _ctmConfigPath() internal view override returns (string memory) {
        return "/test/foundry/l1/integration/deploy-scripts/script-config/config-deploy-ctm-no-airbender.toml";
    }

    function setUp() public {
        _deployL1Contracts();
        _deployTokens();
        _registerNewTokens(tokens);
        _deployEra();
    }

    function test_chainIsCreatedWithTheAirbenderLaneMaskedOff() public view {
        assertEq(
            IZKChain(getZKChainAddress(eraZKChainId)).disabledProofSystems(),
            AIRBENDER_PROOF_SYSTEM_DISABLED,
            "a chain whose verifier has no Airbender lane must be created with that lane masked off"
        );
    }

    /// The mask has to match the wiring: the gate is what accepts the combined envelope, and it was never
    /// deployed here.
    function test_chainVerifierIsNotTheGate() public {
        address verifier = IZKChain(getZKChainAddress(eraZKChainId)).getVerifier();

        vm.expectRevert();
        IEraMultiProofVerifier(verifier).acceptedProofType();
    }
}
