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
        assertTrue(IVerifier(boojum).verificationKeyHash() != bytes32(0), "Boojum verifier has no key");
        assertTrue(IVerifier(airbender).verificationKeyHash() != bytes32(0), "Airbender verifier has no key");
        assertEq(verifier.verificationKeyHash(), IVerifier(boojum).verificationKeyHash());
    }

    /// Tooling reads the verifiers off the chain verifier.
    function test_addressIntrospectorResolvesTheVerifiers() public {
        CTMDeployedAddresses memory info = AddressIntrospector.getCTMAddresses(
            ChainTypeManagerBase(address(addresses.chainTypeManager))
        );

        assertEq(info.stateTransition.verifiers.verifier, address(_verifier()), "chain verifier not resolved");
        assertEq(info.stateTransition.verifiers.verifierFflonk, address(_verifier().BOOJUM_VERIFIER()));
        assertEq(info.stateTransition.verifiers.airbenderVerifierPlonk, address(_verifier().AIRBENDER_VERIFIER()));
        assertEq(info.stateTransition.verifiers.verifierPlonk, address(0), "Era chains have no PLONK verifier");
    }
}
