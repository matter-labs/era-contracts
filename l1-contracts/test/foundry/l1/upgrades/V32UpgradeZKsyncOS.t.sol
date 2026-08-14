// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {V32UpgradeZKsyncOS} from "contracts/upgrades/V32UpgradeZKsyncOS.sol";
import {IL2V32Upgrade} from "contracts/upgrades/IL2V32Upgrade.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {IERC20Metadata} from "@openzeppelin/contracts-v4/token/ERC20/extensions/IERC20Metadata.sol";
import {ETH_TOKEN_ADDRESS, ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE} from "contracts/common/Config.sol";
import {
    BaseTokenPreV31TotalSupplyNotSet,
    LowerBoundAlreadyRecorded,
    LowerBoundNotRecorded,
    PriorityQueueNotReady
} from "contracts/common/L1ContractErrors.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {IPriorityOpLowerBound} from "contracts/upgrades/IPriorityOpLowerBound.sol";
import {PriorityOpLowerBound} from "contracts/upgrades/PriorityOpLowerBound.sol";

import {BaseUpgrade} from "./_SharedBaseUpgrade.t.sol";
import {BaseUpgradeUtils} from "./_SharedBaseUpgradeUtils.t.sol";

contract DummyV32UpgradeZKsyncOS is V32UpgradeZKsyncOS, BaseUpgradeUtils {
    constructor(IPriorityOpLowerBound _priorityOpLowerBound) V32UpgradeZKsyncOS(_priorityOpLowerBound) {}

    function setBridgehub(address _bridgehub) public {
        s.bridgehub = _bridgehub;
    }

    function setChainId(uint256 _chainId) public {
        s.chainId = _chainId;
    }

    function setZKsyncOS(bool _zksyncOS) public {
        s.zksyncOS = _zksyncOS;
    }

    function setBatchCounters(uint256 _committed, uint256 _executed) public {
        s.totalBatchesCommitted = _committed;
        s.totalBatchesExecuted = _executed;
    }

    function setBaseTokenHasTotalSupply(bool _v) public {
        s.baseTokenHasTotalSupply = _v;
    }

    function getBaseTokenHasTotalSupply() public view returns (bool) {
        return s.baseTokenHasTotalSupply;
    }

    function getL2SystemContractsUpgradeTxHash() public view returns (bytes32) {
        return s.l2SystemContractsUpgradeTxHash;
    }
}

/// @notice Unit tests for the v32-specific ZKsync OS per-chain upgrade: the v31 base-token backfill
///         prerequisite it adds on top of {DefaultUpgradeZKsyncOS} (whose behavior is covered in
///         `DefaultUpgradeZKsyncOS.t.sol`).
contract V32UpgradeZKsyncOSTest is BaseUpgrade {
    DummyV32UpgradeZKsyncOS internal upgradeContract;
    PriorityOpLowerBound internal priorityOpLowerBound;

    address internal mockChainTypeManager = makeAddr("mockChainTypeManager");
    address internal mockVerifier = makeAddr("mockVerifier");
    address internal mockBridgehub = makeAddr("mockBridgehub");
    address internal mockAssetRouter = makeAddr("mockAssetRouter");
    address internal mockNativeTokenVault = makeAddr("mockNativeTokenVault");
    address internal ctmDeployer = makeAddr("ctmDeployer");
    address internal delegateTo = makeAddr("l2V32UpgradeDelegate");

    uint256 internal constant CHAIN_ID = 271;
    uint256 internal constant BASE_TOKEN_ORIGIN_CHAIN_ID = 1;
    bytes32 internal constant BASE_TOKEN_ASSET_ID = keccak256("baseTokenAssetId");
    bytes internal constant FIXED_FORCE_DEPLOYMENTS_DATA = hex"c0ffee";
    uint256 internal constant TOTAL_PRIORITY_TXS_AT_RECORD_TIME = 7;

    function setUp() public {
        priorityOpLowerBound = new PriorityOpLowerBound();
        upgradeContract = new DummyV32UpgradeZKsyncOS(priorityOpLowerBound);

        _prepareProposedUpgrade();

        upgradeContract.setPriorityTxMaxGasLimit(1 ether);
        upgradeContract.setPriorityTxMaxPubdata(1000000);
        upgradeContract.setChainTypeManager(mockChainTypeManager);
        proposedUpgrade.verifier = mockVerifier;
        upgradeContract.setBridgehub(mockBridgehub);
        upgradeContract.setChainId(CHAIN_ID);
        upgradeContract.setZKsyncOS(true);
        // The default shape: every committed batch processed, backfill prerequisite satisfied
        // (flag set on v31, bound recorded, priority ops processed through it).
        upgradeContract.setBatchCounters(7, 7);
        upgradeContract.setBaseTokenHasTotalSupply(true);
        _recordLowerBound();
        _mockFirstUnprocessedPriorityTx(TOTAL_PRIORITY_TXS_AT_RECORD_TIME);
        _mockEcosystemForSubstitution();

        proposedUpgrade.l2ProtocolUpgradeTx.data = _placeholderUpgradeTxData();
        // ZKsync OS chains use their own system-upgrade transaction type.
        proposedUpgrade.l2ProtocolUpgradeTx.txType = ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE;
    }

    /// @dev Records the chain's lower bound in the registry, mocking the pre-upgrade getters the
    /// registry reads on the chain (the dummy upgrade contract stands in for the diamond).
    function _recordLowerBound() internal {
        vm.mockCall(
            address(upgradeContract),
            abi.encodeWithSelector(IGetters.baseTokenSupportsTotalSupply.selector),
            abi.encode(true)
        );
        vm.mockCall(
            address(upgradeContract),
            abi.encodeWithSelector(IGetters.getTotalPriorityTxs.selector),
            abi.encode(TOTAL_PRIORITY_TXS_AT_RECORD_TIME)
        );
        priorityOpLowerBound.lowerBoundPriorityOp(address(upgradeContract));
    }

    function _mockFirstUnprocessedPriorityTx(uint256 _value) internal {
        vm.mockCall(
            address(upgradeContract),
            abi.encodeWithSelector(IGetters.getFirstUnprocessedPriorityTx.selector),
            abi.encode(_value)
        );
    }

    /// @notice With the prerequisite satisfied the inherited upgrade path runs to completion.
    function test_upgradesWhenBackfillPrerequisiteSatisfied() public {
        bytes32 result = upgradeContract.upgrade(proposedUpgrade);

        assertEq(result, Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE);
        assertEq(upgradeContract.getProtocolVersion(), proposedUpgrade.newProtocolVersion);
        assertTrue(upgradeContract.getBaseTokenHasTotalSupply(), "the tracked-supply flag must survive the upgrade");
    }

    /// @notice The upgrade is forbidden until the chain's pre-v32 base-token total supply was
    /// backfilled while it ran v31 (this release has no backfill path).
    function test_revertWhen_baseTokenTotalSupplyNotBackfilled() public {
        upgradeContract.setBaseTokenHasTotalSupply(false);

        vm.expectRevert(BaseTokenPreV31TotalSupplyNotSet.selector);
        upgradeContract.upgrade(proposedUpgrade);
    }

    /// @notice The backfill flag alone is not enough: a lower bound proving the backfill's L2
    /// execution must have been recorded in the registry.
    function test_revertWhen_lowerBoundNotRecorded() public {
        priorityOpLowerBound = new PriorityOpLowerBound(); // fresh registry: nothing recorded
        upgradeContract = new DummyV32UpgradeZKsyncOS(priorityOpLowerBound);
        upgradeContract.setBaseTokenHasTotalSupply(true);
        upgradeContract.setBatchCounters(7, 7);

        vm.expectRevert(LowerBoundNotRecorded.selector);
        upgradeContract.upgrade(proposedUpgrade);
    }

    /// @notice The upgrade must refuse to run until every priority op below the recorded bound —
    /// the backfill service transaction included — has been processed.
    function test_revertWhen_priorityOpsBelowLowerBoundNotProcessed() public {
        _mockFirstUnprocessedPriorityTx(TOTAL_PRIORITY_TXS_AT_RECORD_TIME - 1);

        vm.expectRevert(PriorityQueueNotReady.selector);
        upgradeContract.upgrade(proposedUpgrade);
    }

    /// @notice A chain whose supply was backfilled but that never had a single priority op — a
    /// chain created on v31 gets the flag from DiamondInit with no backfill service transaction to
    /// prove — records a legitimate zero bound and upgrades with zero ops processed (0 >= 0).
    function test_upgradesWithZeroLowerBoundAndNoPriorityOpsProcessed() public {
        // Fresh registry + upgrade contract, so the zero bound is recorded from scratch.
        priorityOpLowerBound = new PriorityOpLowerBound();
        upgradeContract = new DummyV32UpgradeZKsyncOS(priorityOpLowerBound);

        upgradeContract.setPriorityTxMaxGasLimit(1 ether);
        upgradeContract.setPriorityTxMaxPubdata(1000000);
        upgradeContract.setChainTypeManager(mockChainTypeManager);
        proposedUpgrade.verifier = mockVerifier;
        upgradeContract.setBridgehub(mockBridgehub);
        upgradeContract.setChainId(CHAIN_ID);
        upgradeContract.setZKsyncOS(true);
        upgradeContract.setBatchCounters(7, 7);
        upgradeContract.setBaseTokenHasTotalSupply(true);

        vm.mockCall(
            address(upgradeContract),
            abi.encodeWithSelector(IGetters.baseTokenSupportsTotalSupply.selector),
            abi.encode(true)
        );
        vm.mockCall(
            address(upgradeContract),
            abi.encodeWithSelector(IGetters.getTotalPriorityTxs.selector),
            abi.encode(uint256(0))
        );
        priorityOpLowerBound.lowerBoundPriorityOp(address(upgradeContract));
        assertTrue(priorityOpLowerBound.recorded(address(upgradeContract)), "the zero bound must count as recorded");
        assertEq(priorityOpLowerBound.lowerBound(address(upgradeContract)), 0);

        _mockFirstUnprocessedPriorityTx(0);

        assertEq(upgradeContract.upgrade(proposedUpgrade), Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE);
        assertEq(upgradeContract.getProtocolVersion(), proposedUpgrade.newProtocolVersion);
    }

    /// @notice The anti-griefing property of the lower-bound design: priority ops enqueued AFTER
    /// the bound was recorded may stay pending without blocking the upgrade (an empty-queue
    /// requirement would let anyone stall it indefinitely).
    function test_upgradesWithPendingUnrelatedPriorityOps() public {
        // Two unrelated ops were enqueued after the bound: total 9, first unprocessed still 7.
        _mockFirstUnprocessedPriorityTx(TOTAL_PRIORITY_TXS_AT_RECORD_TIME);
        vm.mockCall(
            address(upgradeContract),
            abi.encodeWithSelector(IGetters.getTotalPriorityTxs.selector),
            abi.encode(TOTAL_PRIORITY_TXS_AT_RECORD_TIME + 2)
        );
        vm.mockCall(
            address(upgradeContract),
            abi.encodeWithSelector(IGetters.getPriorityQueueSize.selector),
            abi.encode(2)
        );

        assertEq(upgradeContract.upgrade(proposedUpgrade), Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE);
    }

    function _placeholderUpgradeTxData() internal view returns (bytes memory) {
        bytes memory innerCalldata = abi.encodeCall(
            IL2V32Upgrade.upgrade,
            (true, ctmDeployer, FIXED_FORCE_DEPLOYMENTS_DATA, hex"00")
        );
        return
            abi.encodeCall(
                IComplexUpgrader.forceDeployAndUpgradeUniversal,
                (new IComplexUpgrader.UniversalContractUpgradeInfo[](0), delegateTo, innerCalldata)
            );
    }

    function _mockEcosystemForSubstitution() internal {
        vm.mockCall(
            mockBridgehub,
            abi.encodeWithSelector(IBridgehubBase.assetRouter.selector),
            abi.encode(mockAssetRouter)
        );
        vm.mockCall(
            mockAssetRouter,
            abi.encodeWithSelector(IL1AssetRouter.nativeTokenVault.selector),
            abi.encode(mockNativeTokenVault)
        );
        vm.mockCall(
            mockBridgehub,
            abi.encodeWithSelector(IBridgehubBase.baseTokenAssetId.selector, CHAIN_ID),
            abi.encode(BASE_TOKEN_ASSET_ID)
        );
        vm.mockCall(
            mockNativeTokenVault,
            abi.encodeWithSelector(INativeTokenVaultBase.originChainId.selector, BASE_TOKEN_ASSET_ID),
            abi.encode(BASE_TOKEN_ORIGIN_CHAIN_ID)
        );
        vm.mockCall(
            mockNativeTokenVault,
            abi.encodeWithSelector(INativeTokenVaultBase.originToken.selector, BASE_TOKEN_ASSET_ID),
            abi.encode(ETH_TOKEN_ADDRESS)
        );
    }
}

contract PriorityOpLowerBoundTest is Test {
    PriorityOpLowerBound internal registry;
    address internal chain;

    uint256 internal constant TOTAL_PRIORITY_TXS = 42;

    function setUp() public {
        registry = new PriorityOpLowerBound();
        chain = makeAddr("chainDiamond");
        vm.mockCall(chain, abi.encodeWithSelector(IGetters.baseTokenSupportsTotalSupply.selector), abi.encode(true));
        vm.mockCall(
            chain,
            abi.encodeWithSelector(IGetters.getTotalPriorityTxs.selector),
            abi.encode(TOTAL_PRIORITY_TXS)
        );
    }

    function test_recordsCurrentPriorityOpCountOnce() public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit IPriorityOpLowerBound.LowerBoundRecorded(chain, TOTAL_PRIORITY_TXS);

        registry.lowerBoundPriorityOp(chain);

        assertTrue(registry.recorded(chain), "the recording must be marked");
        assertEq(registry.lowerBound(chain), TOTAL_PRIORITY_TXS, "the current priority-op count should be pinned");
    }

    /// @dev First call wins: a later caller must not be able to raise the bound and delay the upgrade.
    function test_revertsOnSecondRecording() public {
        registry.lowerBoundPriorityOp(chain);

        vm.mockCall(
            chain,
            abi.encodeWithSelector(IGetters.getTotalPriorityTxs.selector),
            abi.encode(TOTAL_PRIORITY_TXS + 10)
        );
        vm.expectRevert(LowerBoundAlreadyRecorded.selector);
        registry.lowerBoundPriorityOp(chain);

        assertEq(registry.lowerBound(chain), TOTAL_PRIORITY_TXS, "the first recorded bound must stay");
    }

    /// @dev A bound recorded before the backfill was requested could miss it, so recording is
    /// only possible once the chain reports the supply as tracked.
    function test_revertsWhenBaseTokenTotalSupplyNotBackfilled() public {
        vm.mockCall(chain, abi.encodeWithSelector(IGetters.baseTokenSupportsTotalSupply.selector), abi.encode(false));

        vm.expectRevert(BaseTokenPreV31TotalSupplyNotSet.selector);
        registry.lowerBoundPriorityOp(chain);
    }

    /// @dev A chain created on v31 legitimately has zero priority ops (its flag comes from
    /// DiamondInit, with no backfill to prove): recording a zero bound must work and still be
    /// protected by first-call-wins.
    function test_recordsZeroForChainWithNoPriorityOps() public {
        vm.mockCall(chain, abi.encodeWithSelector(IGetters.getTotalPriorityTxs.selector), abi.encode(uint256(0)));

        registry.lowerBoundPriorityOp(chain);

        assertTrue(registry.recorded(chain), "a zero bound must still count as recorded");
        assertEq(registry.lowerBound(chain), 0);

        vm.expectRevert(LowerBoundAlreadyRecorded.selector);
        registry.lowerBoundPriorityOp(chain);
    }
}
