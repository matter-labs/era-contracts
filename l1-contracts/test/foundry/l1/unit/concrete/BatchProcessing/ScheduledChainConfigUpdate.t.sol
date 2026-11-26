// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ChainConfigTest} from "./_ChainConfig_Shared.t.sol";
import {Utils, TEST_ROLLUP_DA_MANAGER_OWNER} from "../Utils/Utils.sol";
import {
    L2DACommitmentScheme,
    PubdataContent,
    ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT,
    ZKSYNC_OS_MAX_BLOCK_GAS_LIMIT
} from "contracts/common/Config.sol";
import {ChainConfigUpdate} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IChainConfig} from "contracts/state-transition/chain-interfaces/IChainConfig.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {L1DAValidatorAddressIsZero, NotSettlementLayer} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {
    ChainConfigHashMismatch,
    ChainConfigUpdateAlreadyDue,
    InvalidDAForPermanentRollup,
    InvalidL2DACommitmentScheme,
    NoPendingChainConfigUpdate,
    NotCompatibleWithPriorityMode,
    PubdataContentLockedForPermanentRollup,
    Unauthorized,
    UpgradeTimestampNotReached,
    ZKsyncOSChainConfigUpdateWithUnverifiedBatches,
    ZKsyncOSMaxTxGasLimitTooHigh,
    ZKsyncOSMaxTxGasLimitTooLow,
    ZeroUpgradeTimestamp
} from "contracts/common/L1ContractErrors.sol";

/// @notice Scheduled chain configuration updates: the admin schedules, a validator applies through the
/// ValidatorTimelock's `UPGRADER_ROLE`. See {protocol-docs/chain-config.md#scheduled-configuration-updates}.
contract ScheduledChainConfigUpdateTest is ChainConfigTest {
    uint256 internal constant DELAY = 1 hours;

    /*//////////////////////////////////////////////////////////////
                                SCHEDULE
    //////////////////////////////////////////////////////////////*/

    function test_scheduleStoresTheUpdate() public {
        bytes32 configHash = _currentChainConfigHash();
        ChainConfigUpdate memory update = _changingUpdate();

        _schedule(update, block.timestamp + DELAY);

        _assertPending(update, block.timestamp + DELAY);
        assertEq(_currentChainConfigHash(), configHash);
    }

    function testFuzz_nonAdminCannotSchedule(address _caller) public {
        vm.assume(_caller != getters.getAdmin());
        ChainConfigUpdate memory update = _changingUpdate();

        vm.prank(_caller);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, _caller));
        chainConfig.scheduleChainConfigUpdate(update, block.timestamp + DELAY);

        _assertNoPending();
    }

    function test_validatorCannotSchedule() public {
        ChainConfigUpdate memory update = _changingUpdate();
        address[2] memory validators = [validator, address(validatorTimelock)];
        for (uint256 i = 0; i < validators.length; ++i) {
            vm.prank(validators[i]);
            vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, validators[i]));
            chainConfig.scheduleChainConfigUpdate(update, block.timestamp + DELAY);
        }

        _assertNoPending();
    }

    function test_RevertWhen_scheduleWithZeroTimestamp() public {
        ChainConfigUpdate memory update = _changingUpdate();

        vm.prank(getters.getAdmin());
        vm.expectRevert(ZeroUpgradeTimestamp.selector);
        chainConfig.scheduleChainConfigUpdate(update, 0);
    }

    function test_RevertWhen_scheduleNotOnSettlementLayer() public {
        ChainConfigUpdate memory update = _changingUpdate();
        utilsFacet.util_setSettlementLayer(makeAddr("settlementLayer"));

        vm.prank(getters.getAdmin());
        vm.expectRevert(NotSettlementLayer.selector);
        chainConfig.scheduleChainConfigUpdate(update, block.timestamp + DELAY);
    }

    function test_scheduleReplacesAnUpdateNotYetDue() public {
        _schedule(_changingUpdate(), block.timestamp + DELAY);
        ChainConfigUpdate memory replacement = _currentConfig();
        replacement.largeContractsEnabled = true;

        vm.warp(block.timestamp + DELAY - 1);
        _schedule(replacement, block.timestamp + 2 * DELAY);

        _assertPending(replacement, block.timestamp + 2 * DELAY);
    }

    function test_RevertWhen_scheduleReplacesADueUpdate() public {
        uint256 timestamp = block.timestamp + DELAY;
        ChainConfigUpdate memory update = _changingUpdate();
        _schedule(update, timestamp);
        ChainConfigUpdate memory replacement = _currentConfig();
        replacement.largeContractsEnabled = true;

        vm.warp(timestamp);
        vm.prank(getters.getAdmin());
        vm.expectRevert(abi.encodeWithSelector(ChainConfigUpdateAlreadyDue.selector, timestamp));
        chainConfig.scheduleChainConfigUpdate(replacement, block.timestamp + DELAY);
        _assertPending(update, timestamp);

        // Replacing a due update takes an explicit cancel.
        vm.prank(getters.getAdmin());
        chainConfig.cancelChainConfigUpdate();
        _schedule(replacement, block.timestamp + DELAY);
        _assertPending(replacement, block.timestamp + DELAY);
    }

    function testFuzz_RevertWhen_scheduleMaxTxGasLimitTooLow(uint64 _maxTxGasLimit) public {
        _maxTxGasLimit = uint64(bound(_maxTxGasLimit, 0, ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT - 1));
        ChainConfigUpdate memory update = _currentConfig();
        update.maxTxGasLimit = _maxTxGasLimit;

        vm.prank(getters.getAdmin());
        vm.expectRevert(ZKsyncOSMaxTxGasLimitTooLow.selector);
        chainConfig.scheduleChainConfigUpdate(update, block.timestamp + DELAY);
    }

    function testFuzz_RevertWhen_scheduleMaxTxGasLimitTooHigh(uint64 _maxTxGasLimit) public {
        _maxTxGasLimit = uint64(bound(_maxTxGasLimit, uint256(ZKSYNC_OS_MAX_BLOCK_GAS_LIMIT) + 1, type(uint64).max));
        ChainConfigUpdate memory update = _currentConfig();
        update.maxTxGasLimit = _maxTxGasLimit;

        vm.prank(getters.getAdmin());
        vm.expectRevert(ZKsyncOSMaxTxGasLimitTooHigh.selector);
        chainConfig.scheduleChainConfigUpdate(update, block.timestamp + DELAY);
    }

    function test_RevertWhen_scheduleZeroL1DAValidator() public {
        ChainConfigUpdate memory update = _currentConfig();
        update.l1DAValidator = address(0);

        vm.prank(getters.getAdmin());
        vm.expectRevert(L1DAValidatorAddressIsZero.selector);
        chainConfig.scheduleChainConfigUpdate(update, block.timestamp + DELAY);
    }

    function test_RevertWhen_scheduleNoDACommitmentScheme() public {
        ChainConfigUpdate memory update = _currentConfig();
        update.l2DACommitmentScheme = L2DACommitmentScheme.NONE;

        vm.prank(getters.getAdmin());
        vm.expectRevert(abi.encodeWithSelector(InvalidL2DACommitmentScheme.selector, L2DACommitmentScheme.NONE));
        chainConfig.scheduleChainConfigUpdate(update, block.timestamp + DELAY);
    }

    function test_RevertWhen_scheduleFilteringWithPriorityModeAllowed() public {
        _requestPriorityOp();
        _allowPriorityMode();
        ChainConfigUpdate memory update = _currentConfig();
        update.l1TxFilteringEnabled = true;

        vm.prank(getters.getAdmin());
        vm.expectRevert(NotCompatibleWithPriorityMode.selector);
        chainConfig.scheduleChainConfigUpdate(update, block.timestamp + DELAY);
    }

    function test_RevertWhen_schedulePubdataChangeForPermanentRollup() public {
        _makePermanentRollup();
        ChainConfigUpdate memory update = _currentConfig();
        update.pubdataContent = PubdataContent.LOGS_ONLY;

        vm.prank(getters.getAdmin());
        vm.expectRevert(PubdataContentLockedForPermanentRollup.selector);
        chainConfig.scheduleChainConfigUpdate(update, block.timestamp + DELAY);
    }

    function test_RevertWhen_scheduleDisallowedDAPairForPermanentRollup() public {
        _makePermanentRollup();
        ChainConfigUpdate memory update = _currentConfig();
        update.l1DAValidator = makeAddr("disallowedL1DAValidator");

        vm.prank(getters.getAdmin());
        vm.expectRevert(InvalidDAForPermanentRollup.selector);
        chainConfig.scheduleChainConfigUpdate(update, block.timestamp + DELAY);
    }

    function test_scheduleAllowedDAPairForPermanentRollup() public {
        _makePermanentRollup();
        ChainConfigUpdate memory update = _currentConfig();
        update.l1DAValidator = makeAddr("allowedL1DAValidator");
        vm.prank(TEST_ROLLUP_DA_MANAGER_OWNER);
        rollupDAManager.updateDAPair(update.l1DAValidator, update.l2DACommitmentScheme, true);

        _schedule(update, block.timestamp + DELAY);
        _assertPending(update, block.timestamp + DELAY);
    }

    /// @dev Only the fields an update changes are checked: a permanent rollup whose DA pair the RollupDAManager
    /// has since disallowed can still schedule and apply an update that keeps that pair.
    function test_updateKeepingADisallowedDAPairOfAPermanentRollup() public {
        _makePermanentRollup();
        (address l1DAValidator, L2DACommitmentScheme l2DACommitmentScheme) = getters.getDAValidatorPair();
        vm.prank(TEST_ROLLUP_DA_MANAGER_OWNER);
        rollupDAManager.updateDAPair(l1DAValidator, l2DACommitmentScheme, false);
        ChainConfigUpdate memory update = _currentConfig();
        update.maxTxGasLimit = 2 * ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT;

        _schedule(update, block.timestamp + DELAY);
        vm.warp(block.timestamp + DELAY);
        _applyThroughTimelock();

        _assertConfig(update);
    }

    function test_scheduleWithUnverifiedBatches() public {
        _commitFirstBatch();

        _schedule(_changingUpdate(), block.timestamp + DELAY);

        _assertPending(_changingUpdate(), block.timestamp + DELAY);
        assertEq(getters.getTotalBatchesCommitted(), 1);
        assertEq(getters.getTotalBatchesVerified(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                                CANCEL
    //////////////////////////////////////////////////////////////*/

    function test_cancelClearsTheUpdate() public {
        bytes32 configHash = _currentChainConfigHash();
        _schedule(_changingUpdate(), block.timestamp + DELAY);

        vm.expectEmit(true, true, true, true, address(chainConfig));
        emit IChainConfig.ChainConfigUpdateCancelled();
        vm.prank(getters.getAdmin());
        chainConfig.cancelChainConfigUpdate();

        _assertNoPending();
        assertEq(_currentChainConfigHash(), configHash);
    }

    function test_cancelADueUpdate() public {
        ChainConfigUpdate memory update = _changingUpdate();
        _schedule(update, block.timestamp + DELAY);
        vm.warp(block.timestamp + DELAY);

        vm.prank(getters.getAdmin());
        chainConfig.cancelChainConfigUpdate();
        _assertNoPending();

        vm.prank(validator);
        vm.expectRevert(NoPendingChainConfigUpdate.selector);
        validatorTimelock.applyChainConfigUpdate(address(chainConfig));
    }

    function test_RevertWhen_cancelWithNoPendingUpdate() public {
        vm.prank(getters.getAdmin());
        vm.expectRevert(NoPendingChainConfigUpdate.selector);
        chainConfig.cancelChainConfigUpdate();
    }

    function testFuzz_nonAdminCannotCancel(address _caller) public {
        vm.assume(_caller != getters.getAdmin());
        _schedule(_changingUpdate(), block.timestamp + DELAY);

        vm.prank(_caller);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, _caller));
        chainConfig.cancelChainConfigUpdate();

        _assertPending(_changingUpdate(), block.timestamp + DELAY);
    }

    /*//////////////////////////////////////////////////////////////
                                APPLY
    //////////////////////////////////////////////////////////////*/

    /// @dev The node flow: once the update is due, a batch under the new configuration only commits after
    /// the update is applied.
    function test_applyThroughValidatorTimelock() public {
        IExecutor.StoredBatchInfo memory firstBatch = _proveFirstBatch();
        bytes32 oldConfigHash = _currentChainConfigHash();
        ChainConfigUpdate memory oldConfig = _currentConfig();
        ChainConfigUpdate memory update = _changingUpdate();
        bytes32 newConfigHash = _chainConfigHash(update);
        uint256 timestamp = block.timestamp + DELAY;
        _schedule(update, timestamp);

        vm.warp(timestamp);
        newCommitBatchInfoZKsyncOS.batchNumber = 2;
        newCommitBatchInfoZKsyncOS.firstBlockTimestamp = uint64(block.timestamp);
        newCommitBatchInfoZKsyncOS.lastBlockTimestamp = uint64(block.timestamp);
        newCommitBatchInfoZKsyncOS.chainConfigHash = newConfigHash;
        vm.expectRevert(abi.encodeWithSelector(ChainConfigHashMismatch.selector, oldConfigHash, newConfigHash));
        this.commitOSBatchExternal(firstBatch);

        _expectAppliedEvents(oldConfig, update);
        _applyThroughTimelock();

        _assertConfig(update);
        _assertNoPending();
        assertEq(_currentChainConfigHash(), newConfigHash);

        _commitOSBatchGetStored(firstBatch, newCommitBatchInfoZKsyncOS);
        assertEq(getters.getTotalBatchesCommitted(), 2);
    }

    function testFuzz_applyThroughValidatorTimelock(
        uint64 _maxTxGasLimit,
        bool _logsOnly,
        bool _filteringEnabled,
        bool _largeContractsEnabled,
        uint256 _delay
    ) public {
        _delay = bound(_delay, 0, 365 days);
        ChainConfigUpdate memory oldConfig = _currentConfig();
        ChainConfigUpdate memory update = _currentConfig();
        update.maxTxGasLimit = uint64(
            bound(_maxTxGasLimit, ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT, ZKSYNC_OS_MAX_BLOCK_GAS_LIMIT)
        );
        update.pubdataContent = _logsOnly ? PubdataContent.LOGS_ONLY : PubdataContent.FULL_PUBDATA;
        update.l1TxFilteringEnabled = _filteringEnabled;
        update.largeContractsEnabled = _largeContractsEnabled;
        _schedule(update, block.timestamp + _delay);

        vm.warp(block.timestamp + _delay);
        _expectAppliedEvents(oldConfig, update);
        _applyThroughTimelock();

        _assertConfig(update);
        _assertNoPending();
        assertEq(_currentChainConfigHash(), _chainConfigHash(update));
    }

    /// @dev A timestamp in the past makes the update due at once.
    function test_applyAnUpdateScheduledInThePast() public {
        ChainConfigUpdate memory update = _changingUpdate();
        _schedule(update, block.timestamp - 1);

        _applyThroughTimelock();

        _assertConfig(update);
        _assertNoPending();
    }

    function test_adminCanApply() public {
        ChainConfigUpdate memory update = _changingUpdate();
        _schedule(update, block.timestamp + DELAY);
        vm.warp(block.timestamp + DELAY);

        vm.prank(getters.getAdmin());
        chainConfig.applyChainConfigUpdate(address(chainConfig));

        _assertConfig(update);
        _assertNoPending();
    }

    function test_chainTypeManagerCanApply() public {
        ChainConfigUpdate memory update = _changingUpdate();
        _schedule(update, block.timestamp + DELAY);
        vm.warp(block.timestamp + DELAY);

        vm.prank(getters.getChainTypeManager());
        chainConfig.applyChainConfigUpdate(address(chainConfig));

        _assertConfig(update);
        _assertNoPending();
    }

    function testFuzz_RevertWhen_applyByUnauthorizedCaller(address _caller) public {
        vm.assume(_caller != getters.getAdmin());
        vm.assume(_caller != getters.getChainTypeManager());
        vm.assume(_caller != address(validatorTimelock));
        ChainConfigUpdate memory update = _changingUpdate();
        _schedule(update, block.timestamp + DELAY);
        vm.warp(block.timestamp + DELAY);

        vm.prank(_caller);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, _caller));
        chainConfig.applyChainConfigUpdate(address(chainConfig));

        _assertPending(update, block.timestamp);
    }

    /// @dev A validator whitelisted on the chain itself cannot apply without the ValidatorTimelock's
    /// `UPGRADER_ROLE`, and one holding it still has to go through the timelock.
    function test_RevertWhen_applyByValidatorWhitelistedOnTheChain() public {
        address directValidator = makeAddr("directValidator");
        vm.prank(getters.getChainTypeManager());
        admin.setValidator(directValidator, true);
        assertTrue(getters.isValidator(directValidator));
        assertFalse(
            validatorTimelock.hasRole(address(chainConfig), validatorTimelock.UPGRADER_ROLE(), directValidator)
        );
        assertTrue(getters.isValidator(validator));
        assertTrue(validatorTimelock.hasRole(address(chainConfig), validatorTimelock.UPGRADER_ROLE(), validator));
        ChainConfigUpdate memory update = _changingUpdate();
        _schedule(update, block.timestamp + DELAY);
        vm.warp(block.timestamp + DELAY);

        address[2] memory validators = [directValidator, validator];
        for (uint256 i = 0; i < validators.length; ++i) {
            vm.prank(validators[i]);
            vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, validators[i]));
            chainConfig.applyChainConfigUpdate(address(chainConfig));
        }

        _assertPending(update, block.timestamp);
    }

    /// @dev The chain accepts the ValidatorTimelock its chain type manager currently designates.
    function test_RevertWhen_applyThroughATimelockTheChainTypeManagerReplaced() public {
        ChainConfigUpdate memory update = _changingUpdate();
        _schedule(update, block.timestamp + DELAY);
        vm.warp(block.timestamp + DELAY);
        vm.mockCall(
            getters.getChainTypeManager(),
            abi.encodeWithSelector(IChainTypeManager.validatorTimelockPostV29.selector),
            abi.encode(makeAddr("newValidatorTimelock"))
        );

        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(validatorTimelock)));
        validatorTimelock.applyChainConfigUpdate(address(chainConfig));

        _assertPending(update, block.timestamp);
    }

    function test_RevertWhen_applyWithNoPendingUpdate() public {
        vm.prank(validator);
        vm.expectRevert(NoPendingChainConfigUpdate.selector);
        validatorTimelock.applyChainConfigUpdate(address(chainConfig));
    }

    function testFuzz_RevertWhen_applyBeforeTheTimestamp(uint256 _delay, uint256 _elapsed) public {
        _delay = bound(_delay, 1, 365 days);
        _elapsed = bound(_elapsed, 0, _delay - 1);
        ChainConfigUpdate memory update = _changingUpdate();
        uint256 timestamp = block.timestamp + _delay;
        _schedule(update, timestamp);

        vm.warp(block.timestamp + _elapsed);
        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(UpgradeTimestampNotReached.selector, timestamp, block.timestamp));
        validatorTimelock.applyChainConfigUpdate(address(chainConfig));

        _assertPending(update, timestamp);
    }

    function test_applyTheUpdateThatReplacedTheScheduledOne() public {
        _schedule(_changingUpdate(), block.timestamp + DELAY);
        ChainConfigUpdate memory replacement = _currentConfig();
        replacement.maxTxGasLimit = 3 * ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT;
        _schedule(replacement, block.timestamp + 2 * DELAY);
        vm.warp(block.timestamp + 2 * DELAY);

        _applyThroughTimelock();

        _assertConfig(replacement);
        _assertNoPending();
    }

    function test_RevertWhen_applyWithUnverifiedBatches() public {
        ChainConfigUpdate memory oldConfig = _currentConfig();
        ChainConfigUpdate memory update = _changingUpdate();
        _schedule(update, block.timestamp + DELAY);
        _commitFirstBatch();
        vm.warp(block.timestamp + DELAY);

        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(ZKsyncOSChainConfigUpdateWithUnverifiedBatches.selector, 0, 1));
        validatorTimelock.applyChainConfigUpdate(address(chainConfig));

        _assertConfig(oldConfig);
        _assertPending(update, block.timestamp);
    }

    /// @dev The DA pair is not part of the chain configuration hash, so, as with `setDAValidatorPair`,
    /// changing only the DA pair does not wait for the committed batches to be verified.
    function test_applyDAOnlyUpdateWithUnverifiedBatches() public {
        _commitFirstBatch();
        ChainConfigUpdate memory update = _currentConfig();
        update.l1DAValidator = makeAddr("newL1DAValidator");
        update.l2DACommitmentScheme = L2DACommitmentScheme.BLOBS_ZKSYNC_OS;
        _schedule(update, block.timestamp + DELAY);
        vm.warp(block.timestamp + DELAY);

        _applyThroughTimelock();

        _assertConfig(update);
        _assertNoPending();
        assertEq(getters.getTotalBatchesCommitted(), 1);
        assertEq(getters.getTotalBatchesVerified(), 0);
    }

    function test_applyAnUpdateThatChangesNothingWithUnverifiedBatches() public {
        _commitFirstBatch();
        bytes32 configHash = _currentChainConfigHash();
        ChainConfigUpdate memory update = _currentConfig();
        _schedule(update, block.timestamp + DELAY);
        vm.warp(block.timestamp + DELAY);

        _applyThroughTimelock();

        _assertConfig(update);
        _assertNoPending();
        assertEq(_currentChainConfigHash(), configHash);
    }

    /// @dev The update carries target values, so it overrides a setter call made after it was scheduled.
    function test_applyOverridesADirectSetterCallMadeAfterScheduling() public {
        ChainConfigUpdate memory update = _currentConfig();
        update.maxTxGasLimit = 2 * ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT;
        _schedule(update, block.timestamp + DELAY);
        vm.prank(getters.getAdmin());
        admin.setZKsyncOSMaxTxGasLimit(3 * ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT);
        vm.warp(block.timestamp + DELAY);

        _applyThroughTimelock();

        assertEq(getters.getZKsyncOSMaxTxGasLimit(), 2 * ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT);
    }

    function test_RevertWhen_applyFilteringAfterPriorityModeAllowed() public {
        ChainConfigUpdate memory update = _currentConfig();
        update.l1TxFilteringEnabled = true;
        _schedule(update, block.timestamp + DELAY);
        _requestPriorityOp();
        _allowPriorityMode();
        vm.warp(block.timestamp + DELAY);

        vm.prank(validator);
        vm.expectRevert(NotCompatibleWithPriorityMode.selector);
        validatorTimelock.applyChainConfigUpdate(address(chainConfig));

        assertFalse(getters.isZKsyncOSL1TxFilteringEnabled());
    }

    function test_RevertWhen_applyPubdataChangeAfterPermanentRollup() public {
        ChainConfigUpdate memory update = _currentConfig();
        update.pubdataContent = PubdataContent.LOGS_ONLY;
        _schedule(update, block.timestamp + DELAY);
        _makePermanentRollup();
        vm.warp(block.timestamp + DELAY);

        vm.prank(validator);
        vm.expectRevert(PubdataContentLockedForPermanentRollup.selector);
        validatorTimelock.applyChainConfigUpdate(address(chainConfig));

        assertEq(uint256(getters.getPubdataContent()), uint256(PubdataContent.FULL_PUBDATA));
    }

    function test_RevertWhen_applyNotOnSettlementLayer() public {
        ChainConfigUpdate memory update = _changingUpdate();
        _schedule(update, block.timestamp + DELAY);
        vm.warp(block.timestamp + DELAY);
        utilsFacet.util_setSettlementLayer(makeAddr("settlementLayer"));

        vm.prank(validator);
        vm.expectRevert(NotSettlementLayer.selector);
        validatorTimelock.applyChainConfigUpdate(address(chainConfig));
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Called through `this` so that `vm.expectRevert` covers only the commit.
    function commitOSBatchExternal(IExecutor.StoredBatchInfo memory _previousBatch) external {
        _commitOSBatchGetStored(_previousBatch, newCommitBatchInfoZKsyncOS);
    }

    function _currentConfig() internal view returns (ChainConfigUpdate memory config) {
        (config.l1DAValidator, config.l2DACommitmentScheme) = getters.getDAValidatorPair();
        config.pubdataContent = getters.getPubdataContent();
        config.maxTxGasLimit = getters.getZKsyncOSMaxTxGasLimit();
        config.l1TxFilteringEnabled = getters.isZKsyncOSL1TxFilteringEnabled();
        config.largeContractsEnabled = getters.isZKsyncOSLargeContractsEnabled();
    }

    /// @dev Changes every field in the configuration hash; the DA pair stays, so batches still commit.
    function _changingUpdate() internal view returns (ChainConfigUpdate memory update) {
        update = _currentConfig();
        update.maxTxGasLimit = 2 * ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT;
        update.pubdataContent = PubdataContent.LOGS_ONLY;
        update.l1TxFilteringEnabled = true;
        update.largeContractsEnabled = true;
    }

    function _chainConfigHash(ChainConfigUpdate memory _config) internal view returns (bytes32) {
        return
            Utils.chainConfigHash({
                _chainId: getters.getChainId(),
                _maxTxGasLimit: _config.maxTxGasLimit,
                _pubdataContent: _config.pubdataContent,
                _filteringEnabled: _config.l1TxFilteringEnabled,
                _largeContractsEnabled: _config.largeContractsEnabled
            });
    }

    function _schedule(ChainConfigUpdate memory _update, uint256 _timestamp) internal {
        vm.expectEmit(true, true, true, true, address(chainConfig));
        emit IChainConfig.ChainConfigUpdateScheduled(_update, _timestamp);
        vm.prank(getters.getAdmin());
        chainConfig.scheduleChainConfigUpdate(_update, _timestamp);
    }

    function _applyThroughTimelock() internal {
        vm.prank(validator);
        validatorTimelock.applyChainConfigUpdate(address(chainConfig));
    }

    function _expectAppliedEvents(ChainConfigUpdate memory _oldConfig, ChainConfigUpdate memory _update) internal {
        vm.expectEmit(true, true, true, true, address(chainConfig));
        emit IAdmin.NewL1DAValidator(_oldConfig.l1DAValidator, _update.l1DAValidator);
        vm.expectEmit(true, true, true, true, address(chainConfig));
        emit IAdmin.NewL2DACommitmentScheme(_oldConfig.l2DACommitmentScheme, _update.l2DACommitmentScheme);
        vm.expectEmit(true, true, true, true, address(chainConfig));
        emit IAdmin.NewPubdataContent(_oldConfig.pubdataContent, _update.pubdataContent);
        vm.expectEmit(true, true, true, true, address(chainConfig));
        emit IAdmin.NewZKsyncOSMaxTxGasLimit(_oldConfig.maxTxGasLimit, _update.maxTxGasLimit);
        vm.expectEmit(true, true, true, true, address(chainConfig));
        emit IAdmin.NewZKsyncOSL1TxFiltering(_oldConfig.l1TxFilteringEnabled, _update.l1TxFilteringEnabled);
        vm.expectEmit(true, true, true, true, address(chainConfig));
        emit IAdmin.NewZKsyncOSLargeContracts(_oldConfig.largeContractsEnabled, _update.largeContractsEnabled);
        vm.expectEmit(true, true, true, true, address(chainConfig));
        emit IChainConfig.ChainConfigUpdateApplied(_update);
    }

    function _proveFirstBatch() internal returns (IExecutor.StoredBatchInfo memory firstBatch) {
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
        return batches[0];
    }

    function _makePermanentRollup() internal {
        vm.prank(getters.getAdmin());
        admin.makePermanentRollup();
    }

    function _allowPriorityMode() internal {
        vm.prank(getters.getAdmin());
        admin.permanentlyAllowPriorityMode();
        assertTrue(utilsFacet.util_getPriorityModeCanBeActivated());
    }

    function _assertPending(ChainConfigUpdate memory _update, uint256 _timestamp) internal view {
        (ChainConfigUpdate memory pending, uint256 timestamp) = getters.getPendingChainConfigUpdate();
        assertEq(keccak256(abi.encode(pending)), keccak256(abi.encode(_update)));
        assertEq(timestamp, _timestamp);
    }

    function _assertNoPending() internal view {
        ChainConfigUpdate memory empty;
        _assertPending(empty, 0);
    }

    function _assertConfig(ChainConfigUpdate memory _config) internal view {
        assertEq(keccak256(abi.encode(_currentConfig())), keccak256(abi.encode(_config)));
    }
}
