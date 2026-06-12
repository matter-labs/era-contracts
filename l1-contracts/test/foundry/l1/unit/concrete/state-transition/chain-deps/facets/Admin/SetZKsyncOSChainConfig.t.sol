// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AdminTest} from "./_Admin_Shared.t.sol";

import {ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT} from "contracts/common/Config.sol";
import {
    Unauthorized,
    ZKsyncOSChainConfigUpdateWithUnverifiedBatches,
    ZKsyncOSMaxTxGasLimitTooLow
} from "contracts/common/L1ContractErrors.sol";
import {NotZKsyncOS} from "contracts/state-transition/L1StateTransitionErrors.sol";

contract SetZKsyncOSChainConfigTest is AdminTest {
    event NewFriProofVerificationEnabled(bool oldFriProofVerificationEnabled, bool newFriProofVerificationEnabled);
    event NewZKsyncOSMaxTxGasLimit(uint64 oldMaxTxGasLimit, uint64 newMaxTxGasLimit);

    function setUp() public override {
        super.setUp();
        utilsFacet.util_setZksyncOS(true);
    }

    /*//////////////////////////////////////////////////////////////
                    setFriProofVerificationEnabled
    //////////////////////////////////////////////////////////////*/

    function test_setFriProofVerificationEnabled_revertWhen_calledByNonChainTypeManager() public {
        address nonChainTypeManager = makeAddr("nonChainTypeManager");

        vm.startPrank(nonChainTypeManager);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonChainTypeManager));
        adminFacet.setFriProofVerificationEnabled(true);
    }

    function test_setFriProofVerificationEnabled_revertWhen_notZKsyncOS() public {
        utilsFacet.util_setZksyncOS(false);

        vm.startPrank(utilsFacet.util_getChainTypeManager());
        vm.expectRevert(NotZKsyncOS.selector);
        adminFacet.setFriProofVerificationEnabled(true);
    }

    function test_setFriProofVerificationEnabled_revertWhen_unverifiedBatchesExist() public {
        utilsFacet.util_setTotalBatchesCommitted(2);
        utilsFacet.util_setTotalBatchesVerified(1);

        vm.startPrank(utilsFacet.util_getChainTypeManager());
        vm.expectRevert(abi.encodeWithSelector(ZKsyncOSChainConfigUpdateWithUnverifiedBatches.selector, 1, 2));
        adminFacet.setFriProofVerificationEnabled(true);
    }

    function test_setFriProofVerificationEnabled_successfulSet() public {
        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit NewFriProofVerificationEnabled(false, true);

        vm.startPrank(utilsFacet.util_getChainTypeManager());
        adminFacet.setFriProofVerificationEnabled(true);

        assertTrue(utilsFacet.util_getZKsyncOSChainConfig().friProofVerificationEnabled);
    }

    /*//////////////////////////////////////////////////////////////
                        setZKsyncOSMaxTxGasLimit
    //////////////////////////////////////////////////////////////*/

    function test_setZKsyncOSMaxTxGasLimit_revertWhen_calledByNonAdmin() public {
        address nonAdmin = makeAddr("nonAdmin");

        vm.startPrank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonAdmin));
        adminFacet.setZKsyncOSMaxTxGasLimit(ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT);
    }

    function test_setZKsyncOSMaxTxGasLimit_revertWhen_belowEip7825Floor() public {
        vm.startPrank(utilsFacet.util_getAdmin());
        vm.expectRevert(ZKsyncOSMaxTxGasLimitTooLow.selector);
        adminFacet.setZKsyncOSMaxTxGasLimit(ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT - 1);
    }

    function test_setZKsyncOSMaxTxGasLimit_revertWhen_notZKsyncOS() public {
        utilsFacet.util_setZksyncOS(false);

        vm.startPrank(utilsFacet.util_getAdmin());
        vm.expectRevert(NotZKsyncOS.selector);
        adminFacet.setZKsyncOSMaxTxGasLimit(ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT);
    }

    function test_setZKsyncOSMaxTxGasLimit_revertWhen_unverifiedBatchesExist() public {
        utilsFacet.util_setTotalBatchesCommitted(2);
        utilsFacet.util_setTotalBatchesVerified(1);

        vm.startPrank(utilsFacet.util_getAdmin());
        vm.expectRevert(abi.encodeWithSelector(ZKsyncOSChainConfigUpdateWithUnverifiedBatches.selector, 1, 2));
        adminFacet.setZKsyncOSMaxTxGasLimit(ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT);
    }

    function test_setZKsyncOSMaxTxGasLimit_successfulSet() public {
        uint64 newMaxTxGasLimit = ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT * 2;

        // The old value reported is the effective one: the default, since it was never set.
        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(adminFacet));
        emit NewZKsyncOSMaxTxGasLimit(ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT, newMaxTxGasLimit);

        vm.startPrank(utilsFacet.util_getAdmin());
        adminFacet.setZKsyncOSMaxTxGasLimit(newMaxTxGasLimit);

        assertEq(utilsFacet.util_getZKsyncOSChainConfig().maxTxGasLimit, newMaxTxGasLimit);
    }

    function test_setZKsyncOSMaxTxGasLimit_acceptsEip7825Floor() public {
        vm.startPrank(utilsFacet.util_getAdmin());
        adminFacet.setZKsyncOSMaxTxGasLimit(ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT);

        assertEq(utilsFacet.util_getZKsyncOSChainConfig().maxTxGasLimit, ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT);
    }
}
