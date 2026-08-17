// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Test} from "forge-std/Test.sol";

import {AdminFunctions} from "deploy-scripts/AdminFunctions.s.sol";
import {IAdminFunctions} from "contracts/script-interfaces/IAdminFunctions.sol";
import {EraDualVerifier} from "contracts/state-transition/verifiers/EraDualVerifier.sol";
import {Call} from "contracts/governance/Common.sol";
import {
    AIRBENDER_PROOF_SYSTEM,
    ALL_PROOF_SYSTEMS,
    BOOJUM_PROOF_SYSTEM
} from "contracts/state-transition/chain-interfaces/IEraDualVerifier.sol";

/// @notice Unit tests for the `setEnabledProofSystems` calldata generator.
/// @dev The policy itself is covered by `verifiers/EraDualVerifierProofSystemPolicy.t.sol`. What is
/// pinned here is that the script aims the ChainAdmin call at the right contract: the chain's dual
/// verifier, or — on testnet chains, where the chain's verifier is a wrapper that cannot forward the
/// setter — the wrapper's inner `DUAL_VERIFIER()`.
contract AdminFunctionsSetEnabledProofSystemsTest is Test {
    uint256 internal constant CHAIN_ID = 271;

    AdminFunctions internal adminFunctions;

    address internal bridgehub = makeAddr("bridgehub");
    address internal diamondProxy = makeAddr("diamondProxy");
    address internal chainAdmin = makeAddr("chainAdmin");
    address internal ctm = makeAddr("ctm");
    address internal verifier = makeAddr("verifier");
    address internal innerDualVerifier = makeAddr("innerDualVerifier");

    function setUp() public {
        adminFunctions = new AdminFunctions();

        // `Utils.chainInfoFromBridgehubAndChainId` reads all of these.
        vm.mockCall(bridgehub, abi.encodeWithSignature("assetRouter()"), abi.encode(makeAddr("assetRouter")));
        vm.mockCall(bridgehub, abi.encodeWithSignature("getZKChain(uint256)", CHAIN_ID), abi.encode(diamondProxy));
        vm.mockCall(bridgehub, abi.encodeWithSignature("chainTypeManager(uint256)", CHAIN_ID), abi.encode(ctm));
        vm.mockCall(ctm, abi.encodeWithSignature("serverNotifierAddress()"), abi.encode(makeAddr("serverNotifier")));
        vm.mockCall(diamondProxy, abi.encodeWithSignature("getAdmin()"), abi.encode(chainAdmin));
        vm.mockCall(diamondProxy, abi.encodeWithSignature("getVerifier()"), abi.encode(verifier));
    }

    /// Make the chain's verifier look like a plain `EraDualVerifier`: no `IS_TESTNET_VERIFIER`.
    function _mockPlainVerifier() internal {
        vm.mockCallRevert(verifier, abi.encodeWithSignature("IS_TESTNET_VERIFIER()"), "");
    }

    /// Make the chain's verifier look like `EraTestnetVerifier`, which wraps an inner dual verifier.
    function _mockTestnetVerifier() internal {
        vm.mockCall(verifier, abi.encodeWithSignature("IS_TESTNET_VERIFIER()"), abi.encode(true));
        vm.mockCall(verifier, abi.encodeWithSignature("DUAL_VERIFIER()"), abi.encode(innerDualVerifier));
    }

    function test_targetsTheChainsDualVerifier() public {
        _mockPlainVerifier();

        (address executor, Call[] memory calls) = adminFunctions.buildSetEnabledProofSystemsCalls(
            bridgehub,
            CHAIN_ID,
            ALL_PROOF_SYSTEMS
        );

        assertEq(executor, chainAdmin, "the chain admin issues the call");
        assertEq(calls.length, 1);
        assertEq(calls[0].target, verifier, "call must target the chain's verifier");
        assertEq(calls[0].value, 0);
        assertEq(
            calls[0].data,
            abi.encodeCall(EraDualVerifier.setEnabledProofSystems, (diamondProxy, ALL_PROOF_SYSTEMS)),
            "policy must be set for the chain's diamond proxy"
        );
    }

    /// A testnet chain's verifier is a wrapper whose own `msg.sender` would shadow the chain, so it
    /// cannot forward the setter. The call has to go to the inner dual verifier instead.
    function test_targetsInnerDualVerifierForTestnetVerifier() public {
        _mockTestnetVerifier();

        (, Call[] memory calls) = adminFunctions.buildSetEnabledProofSystemsCalls(
            bridgehub,
            CHAIN_ID,
            AIRBENDER_PROOF_SYSTEM
        );

        assertEq(calls[0].target, innerDualVerifier, "must unwrap the testnet verifier");
        assertEq(
            calls[0].data,
            abi.encodeCall(EraDualVerifier.setEnabledProofSystems, (diamondProxy, AIRBENDER_PROOF_SYSTEM)),
            "the chain key stays the diamond proxy, not the verifier"
        );
    }

    function test_supportsBoojumOnly() public {
        _mockPlainVerifier();

        (, Call[] memory calls) = adminFunctions.buildSetEnabledProofSystemsCalls(
            bridgehub,
            CHAIN_ID,
            BOOJUM_PROOF_SYSTEM
        );

        assertEq(
            calls[0].data,
            abi.encodeCall(EraDualVerifier.setEnabledProofSystems, (diamondProxy, BOOJUM_PROOF_SYSTEM))
        );
    }

    /// The verifier rejects these masks on-chain; failing in the script means governance never
    /// signs calldata that is guaranteed to revert.
    function test_revertsOnMaskThatDisablesEverything() public {
        _mockPlainVerifier();

        vm.expectRevert(bytes("setEnabledProofSystems: mask must be non-zero and at most 3"));
        adminFunctions.buildSetEnabledProofSystemsCalls(bridgehub, CHAIN_ID, 0);
    }

    function test_revertsOnMaskWithUnknownBits() public {
        _mockPlainVerifier();

        vm.expectRevert(bytes("setEnabledProofSystems: mask must be non-zero and at most 3"));
        adminFunctions.buildSetEnabledProofSystemsCalls(bridgehub, CHAIN_ID, 4);
    }

    /// `IAdminFunctions` is the surface zkstack tooling calls through.
    function test_interfaceExposesTheSameSelector() public pure {
        assertEq(
            IAdminFunctions.setEnabledProofSystems.selector,
            AdminFunctions.setEnabledProofSystems.selector,
            "IAdminFunctions is out of sync with AdminFunctions"
        );
    }
}
