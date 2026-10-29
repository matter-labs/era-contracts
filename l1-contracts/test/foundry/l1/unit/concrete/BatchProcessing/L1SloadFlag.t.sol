// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ChainConfigTest} from "./_ChainConfig_Shared.t.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IL1MessageRoot} from "contracts/core/message-root/IL1MessageRoot.sol";
import {Unauthorized, ZKsyncOSChainConfigUpdateWithUnverifiedBatches} from "contracts/common/L1ContractErrors.sol";
import {
    L1SloadRequiredByInterop,
    NotL1,
    NotSettlementLayer
} from "contracts/state-transition/L1StateTransitionErrors.sol";

/// @notice The L1SLOAD chain-config flag's Admin setter. See {protocol-docs/chain-config.md#l1sload}.
contract L1SloadFlagTest is ChainConfigTest {
    function test_l1SloadDisabledByDefault() public view {
        assertFalse(getters.isZKsyncOSL1SloadEnabled());
    }

    function testFuzz_adminCanEnableDisableAndRepeat(bool _enabled) public {
        _setL1Sload(_enabled);
        _setL1Sload(_enabled);
        _setL1Sload(!_enabled);
    }

    function testFuzz_nonAdminCannotChangeL1Sload(address _caller, bool _enabled) public {
        vm.assume(_caller != getters.getAdmin());
        vm.prank(_caller);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, _caller));
        admin.setZKsyncOSL1SloadEnabled(_enabled);

        assertFalse(getters.isZKsyncOSL1SloadEnabled());
    }

    function test_revertWhen_notOnL1() public {
        uint256 l1ChainId = block.chainid;
        vm.chainId(l1ChainId + 1);
        address chainAdmin = getters.getAdmin();
        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(NotL1.selector, l1ChainId + 1));
        admin.setZKsyncOSL1SloadEnabled(true);
        vm.chainId(l1ChainId);

        assertFalse(getters.isZKsyncOSL1SloadEnabled());
    }

    function test_revertWhen_notSettlementLayer() public {
        utilsFacet.util_setSettlementLayer(makeAddr("settlementLayer"));
        address chainAdmin = getters.getAdmin();
        vm.prank(chainAdmin);
        vm.expectRevert(NotSettlementLayer.selector);
        admin.setZKsyncOSL1SloadEnabled(true);
    }

    function testFuzz_unverifiedBatchesBlockUpdates(bool _oldEnabled, bool _newEnabled) public {
        _setL1Sload(_oldEnabled);
        _commitFirstBatch();

        vm.prank(getters.getAdmin());
        vm.expectRevert(abi.encodeWithSelector(ZKsyncOSChainConfigUpdateWithUnverifiedBatches.selector, 0, 1));
        admin.setZKsyncOSL1SloadEnabled(_newEnabled);

        assertEq(getters.isZKsyncOSL1SloadEnabled(), _oldEnabled);
    }

    /// @dev The message root is mocked to report the chain enabled, isolating the Admin check; `EnableInterop.t.sol`
    /// runs the real `enableInterop` flow.
    function test_revertWhen_disablingWhileInteropEnabled() public {
        _setL1Sload(true);
        uint256 chainId = getters.getChainId();
        vm.mockCall(address(messageRoot), abi.encodeCall(IL1MessageRoot.isInteropEnabled, (chainId)), abi.encode(true));

        address chainAdmin = getters.getAdmin();
        vm.prank(chainAdmin);
        vm.expectRevert(abi.encodeWithSelector(L1SloadRequiredByInterop.selector, chainId));
        admin.setZKsyncOSL1SloadEnabled(false);
        assertTrue(getters.isZKsyncOSL1SloadEnabled());

        _setL1Sload(true);
    }

    function _setL1Sload(bool _enabled) internal {
        bool oldEnabled = getters.isZKsyncOSL1SloadEnabled();
        vm.expectEmit({
            checkTopic1: true,
            checkTopic2: true,
            checkTopic3: true,
            checkData: true,
            emitter: address(admin)
        });
        emit IAdmin.NewZKsyncOSL1Sload(oldEnabled, _enabled);

        vm.prank(getters.getAdmin());
        admin.setZKsyncOSL1SloadEnabled(_enabled);

        assertEq(getters.isZKsyncOSL1SloadEnabled(), _enabled);
    }
}
