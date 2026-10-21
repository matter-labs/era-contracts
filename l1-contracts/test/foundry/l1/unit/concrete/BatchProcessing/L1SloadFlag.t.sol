// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ChainConfigTest} from "./_ChainConfig_Shared.t.sol";
import {Utils} from "../Utils/Utils.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {IL1MessageRoot} from "contracts/core/message-root/IL1MessageRoot.sol";
import {PubdataContent} from "contracts/common/Config.sol";
import {Unauthorized, ZKsyncOSChainConfigUpdateWithUnverifiedBatches} from "contracts/common/L1ContractErrors.sol";
import {
    L1SloadRequiredByInterop,
    NotL1,
    NotSettlementLayer
} from "contracts/state-transition/L1StateTransitionErrors.sol";

/// @notice The L1SLOAD chain-config flag: its Admin setter, its word in the chain config hash and its tie to interop.
/// See {protocol-docs/chain-config.md#l1sload}.
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

    function test_chainTypeManagerCannotEnableL1Sload() public {
        address chainTypeManager = getters.getChainTypeManager();
        vm.prank(chainTypeManager);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, chainTypeManager));
        admin.setZKsyncOSL1SloadEnabled(true);
    }

    /// @dev The flag gates reads of the L1 interop state, which only exists on L1.
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

    /// @dev A chain settling elsewhere is configured there.
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

    /// @dev The flag is the seventh word of the chain config hash, after `large_contracts_enabled`.
    function test_flagIsCommittedInTheChainConfigHash() public {
        bytes32 disabledHash = getters.getZKsyncOSChainConfigHash();
        assertEq(disabledHash, _currentChainConfigHash());

        _setL1Sload(true);
        bytes32 enabledHash = getters.getZKsyncOSChainConfigHash();
        assertNotEq(enabledHash, disabledHash);
        assertEq(
            enabledHash,
            Utils.chainConfigHash({
                _chainId: getters.getChainId(),
                _maxTxGasLimit: getters.getZKsyncOSMaxTxGasLimit(),
                _pubdataContent: PubdataContent.FULL_PUBDATA,
                _filteringEnabled: false,
                _largeContractsEnabled: false,
                _l1SloadEnabled: true
            })
        );
    }

    /// @dev A batch committed with the flag on proves against the public input that carries it.
    function test_batchCommittedWithTheFlagProves() public {
        _setL1Sload(true);
        IExecutor.StoredBatchInfo[] memory batches = new IExecutor.StoredBatchInfo[](1);
        batches[0] = _commitFirstBatch();
        (uint256 from, uint256 to, bytes memory data) = Utils.encodeProveBatchesData(
            genesisStoredBatchInfo,
            batches,
            proofInput
        );

        vm.prank(validator);
        executor.proveBatchesSharedBridge(address(0), from, to, data);

        assertEq(getters.getTotalBatchesVerified(), 1);
    }

    /// @dev Interop gating on L2 reads L1 through L1SLOAD, so the flag stays on while the chain is enabled for
    /// interop; turning it on again is allowed. The message root is mocked to report the chain enabled, which isolates
    /// the Admin check; `EnableInterop.t.sol` runs the real `enableInterop` flow.
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
