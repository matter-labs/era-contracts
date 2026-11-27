// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ChainConfigTest} from "./_ChainConfig_Shared.t.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {L2DACommitmentScheme, PubdataContent, ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT} from "contracts/common/Config.sol";
import {OnlyNormalMode} from "contracts/common/L1ContractErrors.sol";

/// @notice In Priority Mode a permissionless settler proves batches against the chain config hash and settles
/// them through the chain's DA pair, so the chain admin must not change either while it is active.
/// See {protocol-docs/system/contracts/chain_management/stage1.md#chain-configuration-in-priority-mode}.
contract PriorityModeChainConfigTest is ChainConfigTest {
    /// @dev One call per setter of a field hashed into the chain config hash, each with a value that changes it.
    ///      A field added to `_getZKsyncOSChainConfigHash` must get its setter here: it changes
    ///      `Utils.chainConfigHash`, which `_currentChainConfigHash` calls.
    function _chainConfigSetterCalls() internal pure returns (bytes[] memory calls) {
        calls = new bytes[](4);
        calls[0] = abi.encodeCall(IAdmin.setZKsyncOSMaxTxGasLimit, (ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT + 1));
        calls[1] = abi.encodeCall(IAdmin.setZKsyncOSL1TxFiltering, (true));
        calls[2] = abi.encodeCall(IAdmin.setZKsyncOSLargeContractsEnabled, (true));
        calls[3] = abi.encodeCall(IAdmin.setPubdataContent, (PubdataContent.LOGS_ONLY));
    }

    /// @dev Outside Priority Mode, each listed setter changes the hash: the list covers every hashed field.
    function test_eachChainConfigSetterChangesTheChainConfigHash() public {
        bytes[] memory calls = _chainConfigSetterCalls();
        address chainAdmin = getters.getAdmin();
        for (uint256 i = 0; i < calls.length; ++i) {
            bytes32 hashBefore = _currentChainConfigHash();
            vm.prank(chainAdmin);
            (bool success, ) = address(admin).call(calls[i]);
            assertTrue(success, "the setter works outside Priority Mode");
            assertTrue(_currentChainConfigHash() != hashBefore, "the setter changes the chain config hash");
        }
    }

    function test_revertWhen_chainConfigIsChangedInPriorityMode() public {
        utilsFacet.util_setPriorityModeActivated(true);
        bytes32 hashBefore = _currentChainConfigHash();
        address chainAdmin = getters.getAdmin();

        bytes[] memory calls = _chainConfigSetterCalls();
        for (uint256 i = 0; i < calls.length; ++i) {
            vm.prank(chainAdmin);
            (bool success, bytes memory returnData) = address(admin).call(calls[i]);
            assertFalse(success, "the setter must revert in Priority Mode");
            assertEq(returnData, abi.encodeWithSelector(OnlyNormalMode.selector), "wrong revert");
        }

        assertEq(_currentChainConfigHash(), hashBefore, "the chain config hash must not change");
    }

    function test_revertWhen_daValidatorPairIsChangedInPriorityMode() public {
        utilsFacet.util_setPriorityModeActivated(true);
        L2DACommitmentScheme schemeBefore = utilsFacet.util_getL2DACommimentScheme();
        L2DACommitmentScheme otherScheme = schemeBefore == L2DACommitmentScheme.PUBDATA_KECCAK256
            ? L2DACommitmentScheme.BLOBS_ZKSYNC_OS
            : L2DACommitmentScheme.PUBDATA_KECCAK256;

        vm.prank(getters.getAdmin());
        vm.expectRevert(OnlyNormalMode.selector);
        admin.setDAValidatorPair(makeAddr("anotherL1DAValidator"), otherScheme);

        assertEq(
            uint256(utilsFacet.util_getL2DACommimentScheme()),
            uint256(schemeBefore),
            "the DA pair must not change"
        );
    }

    /// @dev Leaving Priority Mode (`deactivatePriorityMode`) gives the admin its setters back.
    function test_chainConfigSettersWorkAgainAfterPriorityMode() public {
        utilsFacet.util_setPriorityModeActivated(true);
        utilsFacet.util_setPriorityModeActivated(false);

        vm.prank(getters.getAdmin());
        admin.setZKsyncOSLargeContractsEnabled(true);

        assertTrue(getters.isZKsyncOSLargeContractsEnabled());
    }
}
