// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {L2TxMocker} from "./_SharedL2TxMocker.t.sol";

import {AddressIntrospector} from "deploy-scripts/utils/AddressIntrospector.sol";
import {CTMDeployedAddresses} from "deploy-scripts/utils/Types.sol";
import {ChainTypeManagerBase} from "contracts/state-transition/ChainTypeManagerBase.sol";
import {EraMultiProofVerifier} from "contracts/state-transition/verifiers/EraMultiProofVerifier.sol";
import {IEraDualVerifier} from "contracts/state-transition/chain-interfaces/IEraDualVerifier.sol";
import {EraTestnetVerifier} from "contracts/state-transition/verifiers/EraTestnetVerifier.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";

/// @notice Integration checks for a CTM deployed with `airbender_verifier = true`.
contract AirbenderDeploymentTest is L1ContractDeployer, ZKChainDeployer, TokenDeployer, L2TxMocker {
    function _verifier() internal view returns (EraMultiProofVerifier) {
        return EraMultiProofVerifier(address(IZKChain(getZKChainAddress(eraZKChainId)).getVerifier()));
    }

    function setUp() public {
        _deployL1Contracts();
        _deployTokens();
        _registerNewTokens(tokens);
        _deployEra();
    }

    /// Both verifiers are wired into the chain's `EraMultiProofVerifier`.
    function test_chainVerifierIsTheMultiProofVerifier() public view {
        EraMultiProofVerifier verifier = _verifier();

        address boojum = address(verifier.BOOJUM_VERIFIER());
        address airbender = address(verifier.AIRBENDER_VERIFIER());
        assertTrue(boojum != address(0), "Boojum verifier not wired");
        assertTrue(airbender != address(0), "Airbender verifier not wired");
        assertTrue(boojum != airbender, "verifiers must be distinct contracts");
        assertTrue(IVerifier(airbender).verificationKeyHash() != bytes32(0), "Airbender verifier has no key");
    }

    /// Tooling reads `FFLONK_VERIFIER`/`PLONK_VERIFIER` off the chain verifier.
    function test_forwardsSubVerifierGetters() public view {
        IEraDualVerifier chainVerifier = IEraDualVerifier(address(_verifier()));
        IEraDualVerifier router = IEraDualVerifier(address(_verifier().BOOJUM_VERIFIER()));

        assertEq(address(chainVerifier.FFLONK_VERIFIER()), address(router.FFLONK_VERIFIER()));
        assertEq(address(chainVerifier.PLONK_VERIFIER()), address(router.PLONK_VERIFIER()));
        assertTrue(address(router.FFLONK_VERIFIER()) != address(router.PLONK_VERIFIER()));
        assertEq(_verifier().verificationKeyHash(), IVerifier(address(router)).verificationKeyHash());
    }

    function test_addressIntrospectorResolvesTheChainVerifier() public {
        CTMDeployedAddresses memory info = AddressIntrospector.getCTMAddresses(
            ChainTypeManagerBase(address(addresses.chainTypeManager))
        );

        assertTrue(info.stateTransition.verifiers.verifierFflonk != address(0), "fflonk not resolved");
        assertTrue(info.stateTransition.verifiers.verifierPlonk != address(0), "plonk not resolved");
        assertEq(info.stateTransition.verifiers.verifier, address(_verifier()), "chain verifier not resolved");
    }

    /// The Boojum verifier must be the production `EraDualVerifier`, not `EraTestnetVerifier`.
    function test_boojumVerifierIsTheProductionRouter() public {
        EraTestnetVerifier boojum = EraTestnetVerifier(address(_verifier().BOOJUM_VERIFIER()));
        vm.expectRevert();
        boojum.IS_TESTNET_VERIFIER();
    }
}
