// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";
import {IL1MessageRoot} from "contracts/core/message-root/IL1MessageRoot.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";
import {ZKSYNC_OS_MULTI_PROOF_VERIFICATION_TYPE, ZKSYNC_OS_PLONK_VERIFICATION_TYPE} from "contracts/common/Config.sol";
import {NotMultiProofMode, Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {
    InteropAlreadyEnabled,
    SecondProofSystemNotRequired,
    ZKChainNotRegistered
} from "contracts/core/bridgehub/L1BridgehubErrors.sol";

/// @notice `L1MessageRoot.enableInterop` alone. The Bridgehub and the chain are mocked to isolate the message
/// root's checks; the end-to-end flow with real contracts is in `EnableInterop.t.sol`.
/// See {protocol-docs/interop-gating.md#enabling-interop}.
contract L1MessageRootEnableInteropTest is Test {
    uint256 internal constant CHAIN_ID = 271;
    uint256 internal constant GATEWAY_CHAIN_ID = 506;

    address internal bridgehub;
    address internal governance;
    address internal zkChain;
    L1MessageRoot internal messageRoot;

    function setUp() public {
        bridgehub = makeAddr("bridgehub");
        governance = makeAddr("governance");
        zkChain = makeAddr("zkChain");

        // `initialize` requires a Bridgehub without chains.
        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.getAllZKChainChainIDs.selector),
            abi.encode(new uint256[](0))
        );
        messageRoot = L1MessageRoot(
            address(
                new TransparentUpgradeableProxy(
                    address(new L1MessageRoot(bridgehub, makeAddr("chainAssetHandler"))),
                    makeAddr("proxyAdmin"),
                    abi.encodeCall(L1MessageRoot.initialize, ())
                )
            )
        );

        // A registered chain that is ready for interop; each test breaks one condition.
        vm.mockCall(bridgehub, abi.encodeCall(IOwnable.owner, ()), abi.encode(governance));
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.getZKChain, (CHAIN_ID)), abi.encode(zkChain));
        vm.mockCall(zkChain, abi.encodeCall(IGetters.isSecondProofSystemRequired, ()), abi.encode(true));
        vm.mockCall(
            zkChain,
            abi.encodeCall(IGetters.getProofMode, ()),
            abi.encode(ZKSYNC_OS_MULTI_PROOF_VERIFICATION_TYPE)
        );
    }

    function test_enableInterop() public {
        assertFalse(messageRoot.isInteropEnabled(CHAIN_ID));

        vm.expectEmit(true, false, false, true, address(messageRoot));
        emit IL1MessageRoot.InteropEnabled(CHAIN_ID);
        vm.prank(governance);
        messageRoot.enableInterop(CHAIN_ID, true);

        assertTrue(messageRoot.isInteropEnabled(CHAIN_ID));
        assertFalse(messageRoot.isInteropEnabled(GATEWAY_CHAIN_ID), "other chains untouched");
    }

    function test_enableInterop_revertWhen_notBridgehubOwner() public {
        address notOwner = makeAddr("notOwner");
        vm.prank(notOwner);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, notOwner));
        messageRoot.enableInterop(CHAIN_ID, true);
    }

    function test_enableInterop_revertWhen_chainNotRegistered() public {
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.getZKChain, (CHAIN_ID)), abi.encode(address(0)));

        vm.prank(governance);
        vm.expectRevert(ZKChainNotRegistered.selector);
        messageRoot.enableInterop(CHAIN_ID, true);
    }

    function test_enableInterop_revertWhen_alreadyEnabled() public {
        vm.prank(governance);
        messageRoot.enableInterop(CHAIN_ID, true);

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(InteropAlreadyEnabled.selector, CHAIN_ID));
        messageRoot.enableInterop(CHAIN_ID, true);
    }

    function test_enableInterop_revertWhen_secondProofSystemNotRequired() public {
        vm.mockCall(zkChain, abi.encodeCall(IGetters.isSecondProofSystemRequired, ()), abi.encode(false));

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(SecondProofSystemNotRequired.selector, CHAIN_ID));
        messageRoot.enableInterop(CHAIN_ID, true);
    }

    function test_enableInterop_revertWhen_notMultiProofMode() public {
        vm.mockCall(zkChain, abi.encodeCall(IGetters.getProofMode, ()), abi.encode(ZKSYNC_OS_PLONK_VERIFICATION_TYPE));

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(NotMultiProofMode.selector, ZKSYNC_OS_PLONK_VERIFICATION_TYPE));
        messageRoot.enableInterop(CHAIN_ID, true);

        assertFalse(messageRoot.isInteropEnabled(CHAIN_ID));
    }

    /// @notice Without the flag, neither the requirement nor the proof mode is read.
    function test_enableInterop_withoutSecondProofSystem() public {
        vm.mockCall(zkChain, abi.encodeCall(IGetters.isSecondProofSystemRequired, ()), abi.encode(false));
        vm.mockCall(zkChain, abi.encodeCall(IGetters.getProofMode, ()), abi.encode(ZKSYNC_OS_PLONK_VERIFICATION_TYPE));

        vm.expectCall(zkChain, abi.encodeCall(IGetters.isSecondProofSystemRequired, ()), 0);
        vm.expectCall(zkChain, abi.encodeCall(IGetters.getProofMode, ()), 0);
        vm.expectEmit(true, false, false, true, address(messageRoot));
        emit IL1MessageRoot.InteropEnabled(CHAIN_ID);
        vm.prank(governance);
        messageRoot.enableInterop(CHAIN_ID, false);

        assertTrue(messageRoot.isInteropEnabled(CHAIN_ID));
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
