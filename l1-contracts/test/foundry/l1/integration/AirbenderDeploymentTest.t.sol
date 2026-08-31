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
import {AirbenderVerifier} from "contracts/state-transition/verifiers/AirbenderVerifier.sol";
import {IEraDualVerifier} from "contracts/state-transition/chain-interfaces/IEraDualVerifier.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";

/// @notice Deploys the ecosystem with the Airbender lane enabled and exercises the paths that only exist in
/// that configuration.
/// @dev The shared integration config enables the lane, so every integration suite now deploys through it
/// and this one asserts the properties that only hold in that configuration. Before it existed, the whole
/// `airbender_verifier = true` branch — lane deployment order, the gate becoming the chain's verifier, and
/// every downstream consumer of a chain's verifier — was unexecuted by the entire test suite.
contract AirbenderDeploymentTest is L1ContractDeployer, ZKChainDeployer, TokenDeployer, L2TxMocker {
    function _gate() internal view returns (EraMultiProofVerifier) {
        return EraMultiProofVerifier(address(IZKChain(getZKChainAddress(eraZKChainId)).getVerifier()));
    }

    function setUp() public {
        _deployL1Contracts();
        _deployTokens();
        _registerNewTokens(tokens);
        _deployEra();
    }

    /// The chain must settle behind the gate, not the bare Boojum router, and both lanes must be wired.
    function test_chainVerifierIsTheMultiProofGate() public view {
        EraMultiProofVerifier gate = _gate();

        address boojumLane = address(gate.BOOJUM_VERIFIER());
        address airbenderLane = address(gate.AIRBENDER_VERIFIER());
        assertTrue(boojumLane != address(0), "Boojum lane not wired");
        assertTrue(airbenderLane != address(0), "Airbender lane not wired");
        assertTrue(boojumLane != airbenderLane, "lanes must be distinct contracts");
        assertTrue(
            address(AirbenderVerifier(airbenderLane).AIRBENDER_PLONK_VERIFIER()) != address(0),
            "generated Airbender PLONK verifier not wired"
        );
    }

    /// Tooling reads the Boojum sub-verifiers straight off a chain's verifier. With the gate installed that
    /// is the gate itself, so it has to answer for the router it wraps — otherwise chain registration and
    /// upgrade-calldata generation revert.
    function test_gateAnswersSubVerifierIntrospection() public view {
        IEraDualVerifier chainVerifier = IEraDualVerifier(
            address(IZKChain(getZKChainAddress(eraZKChainId)).getVerifier())
        );
        assertTrue(address(chainVerifier.FFLONK_VERIFIER()) != address(0), "FFLONK not introspectable");
        assertTrue(address(chainVerifier.PLONK_VERIFIER()) != address(0), "PLONK not introspectable");
    }

    /// `AddressIntrospector` runs against the live chain verifier and is used by `RegisterZKChain` and by the
    /// upgrade-calldata generator. It must survive the gate and report both lanes rather than zeros.
    function test_addressIntrospectorResolvesTheLanes() public {
        CTMDeployedAddresses memory info = AddressIntrospector.getCTMAddresses(
            ChainTypeManagerBase(address(addresses.chainTypeManager))
        );

        assertTrue(info.stateTransition.verifiers.verifierFflonk != address(0), "fflonk not resolved");
        assertTrue(info.stateTransition.verifiers.verifierPlonk != address(0), "plonk not resolved");
        assertEq(
            info.stateTransition.verifiers.boojumVerifier,
            address(_gate().BOOJUM_VERIFIER()),
            "Boojum router not resolved"
        );
        assertEq(
            info.stateTransition.verifiers.airbenderVerifier,
            address(_gate().AIRBENDER_VERIFIER()),
            "Airbender lane not resolved"
        );
    }

    /// Registering a further chain runs introspection against an already-registered, up-to-date chain — the
    /// exact ordering that makes an introspection failure invisible on the first registration.
    function test_registeringASecondChainStillWorks() public {
        _deployZKChain(ETH_TOKEN_ADDRESS);
    }
}
