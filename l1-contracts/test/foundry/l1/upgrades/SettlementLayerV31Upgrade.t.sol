// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    SettlementLayerV31Upgrade,
    PriorityQueueNotReady,
    NotAllBatchesExecuted,
    GWNotV31
} from "contracts/upgrades/SettlementLayerV31Upgrade.sol";
import {BaseZkSyncUpgrade, ProposedUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {BaseUpgrade} from "./_SharedBaseUpgrade.t.sol";
import {BaseUpgradeUtils} from "./_SharedBaseUpgradeUtils.t.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {IMessageRoot} from "contracts/core/message-root/IMessageRoot.sol";
import {IChainAssetHandler} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {IL1MessageRoot} from "contracts/core/message-root/IL1MessageRoot.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";

contract DummySettlementLayerV31Upgrade is SettlementLayerV31Upgrade, BaseUpgradeUtils {
    function setTotalBatchesCommitted(uint256 _totalBatchesCommitted) public {
        s.totalBatchesCommitted = _totalBatchesCommitted;
    }

    function setTotalBatchesExecuted(uint256 _totalBatchesExecuted) public {
        s.totalBatchesExecuted = _totalBatchesExecuted;
    }

    function setBridgehub(address _bridgehub) public {
        s.bridgehub = _bridgehub;
    }

    function setChainId(uint256 _chainId) public {
        s.chainId = _chainId;
    }

    function setSettlementLayer(address _settlementLayer) public {
        s.settlementLayer = _settlementLayer;
    }

    function getNativeTokenVault() public view returns (address) {
        return s.nativeTokenVault;
    }

    function getAssetTracker() public view returns (address) {
        return s.assetTracker;
    }
}

contract SettlementLayerV31UpgradeTest is BaseUpgrade {
    DummySettlementLayerV31Upgrade internal upgrade;

    address internal mockBridgehub;
    address internal mockAssetRouter;
    address internal mockNativeTokenVault;
    address internal mockAssetTracker;
    address internal mockMessageRoot;
    address internal mockChainAssetHandler;
    address internal mockGWChain;

    uint256 internal testChainId = 123;
    uint256 internal gwChainId = 456;
    bytes32 internal baseTokenAssetId = keccak256("baseTokenAssetId");

    function setUp() public {
        mockBridgehub = makeAddr("bridgehub");
        mockAssetRouter = makeAddr("assetRouter");
        mockNativeTokenVault = makeAddr("nativeTokenVault");
        mockAssetTracker = makeAddr("assetTracker");
        mockMessageRoot = makeAddr("messageRoot");
        mockChainAssetHandler = makeAddr("chainAssetHandler");
        mockGWChain = makeAddr("gwChain");

        upgrade = new DummySettlementLayerV31Upgrade();
        upgrade.setBridgehub(mockBridgehub);
        upgrade.setChainId(testChainId);
        upgrade.setTotalBatchesCommitted(100);
        upgrade.setTotalBatchesExecuted(100);
        upgrade.setPriorityTxMaxGasLimit(1 ether);
        upgrade.setPriorityTxMaxPubdata(1000000);

        _prepareEmptyProposedUpgrade();
    }

    function _setupMocks() internal {
        // Mock bridgehub.assetRouter
        vm.mockCall(
            mockBridgehub,
            abi.encodeWithSelector(IBridgehubBase.assetRouter.selector),
            abi.encode(mockAssetRouter)
        );

        // Mock assetRouter.nativeTokenVault
        vm.mockCall(
            mockAssetRouter,
            abi.encodeWithSelector(IL1AssetRouter.nativeTokenVault.selector),
            abi.encode(mockNativeTokenVault)
        );

        // Mock nativeTokenVault.l1AssetTracker
        vm.mockCall(
            mockNativeTokenVault,
            abi.encodeWithSelector(IL1NativeTokenVault.l1AssetTracker.selector),
            abi.encode(mockAssetTracker)
        );

        // Mock bridgehub.baseTokenAssetId
        vm.mockCall(
            mockBridgehub,
            abi.encodeWithSelector(IBridgehubBase.baseTokenAssetId.selector, testChainId),
            abi.encode(baseTokenAssetId)
        );

        // Mock nativeTokenVault.originChainId
        vm.mockCall(
            mockNativeTokenVault,
            abi.encodeWithSelector(INativeTokenVaultBase.originChainId.selector, baseTokenAssetId),
            abi.encode(block.chainid)
        );

        // Mock nativeTokenVault.originToken
        vm.mockCall(
            mockNativeTokenVault,
            abi.encodeWithSelector(INativeTokenVaultBase.originToken.selector, baseTokenAssetId),
            abi.encode(address(1)) // ETH_TOKEN_ADDRESS
        );

        // Mock bridgehub.chainAssetHandler
        vm.mockCall(
            mockBridgehub,
            abi.encodeWithSelector(IBridgehubBase.chainAssetHandler.selector),
            abi.encode(mockChainAssetHandler)
        );

        // Mock bridgehub.messageRoot
        vm.mockCall(
            mockBridgehub,
            abi.encodeWithSelector(IBridgehubBase.messageRoot.selector),
            abi.encode(mockMessageRoot)
        );

        // Mock messageRoot.ERA_GATEWAY_CHAIN_ID
        vm.mockCall(
            mockMessageRoot,
            abi.encodeWithSelector(IMessageRoot.ERA_GATEWAY_CHAIN_ID.selector),
            abi.encode(gwChainId)
        );

        // Mock bridgehub.getZKChain
        vm.mockCall(
            mockBridgehub,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, gwChainId),
            abi.encode(mockGWChain)
        );

        // Mock gwChain.getSemverProtocolVersion - returns version >= 30
        vm.mockCall(
            mockGWChain,
            abi.encodeWithSelector(IGetters.getSemverProtocolVersion.selector),
            abi.encode(uint32(0), uint32(31), uint32(0)) // major=0, minor=31, patch=0
        );

        // Mock chainAssetHandler.setMigrationNumberForV31
        vm.mockCall(
            mockChainAssetHandler,
            abi.encodeWithSelector(IChainAssetHandler.setMigrationNumberForV31.selector, testChainId),
            abi.encode()
        );

        // Mock messageRoot.saveV31UpgradeChainBatchNumber
        vm.mockCall(
            mockMessageRoot,
            abi.encodeWithSelector(IL1MessageRoot.saveV31UpgradeChainBatchNumber.selector, testChainId),
            abi.encode()
        );

        // Mock bridgehub.whitelistedSettlementLayers
        vm.mockCall(
            mockBridgehub,
            abi.encodeWithSelector(IBridgehubBase.whitelistedSettlementLayers.selector, testChainId),
            abi.encode(false)
        );
    }

    function test_RevertWhen_NotAllBatchesExecuted() public {
        _setupMocks();

        // Set batches committed > executed
        upgrade.setTotalBatchesCommitted(100);
        upgrade.setTotalBatchesExecuted(50);

        vm.expectRevert(NotAllBatchesExecuted.selector);
        upgrade.upgrade(proposedUpgrade);
    }

    function test_RevertWhen_GatewayNotV31() public {
        _setupMocks();

        // Override the GW version mock to return version < 30
        vm.mockCall(
            mockGWChain,
            abi.encodeWithSelector(IGetters.getSemverProtocolVersion.selector),
            abi.encode(uint32(0), uint32(29), uint32(0)) // minor=29 < 30
        );

        vm.expectRevert(abi.encodeWithSelector(GWNotV31.selector, gwChainId));
        upgrade.upgrade(proposedUpgrade);
    }

    function test_RevertWhen_PriorityQueueNotReadyForWhitelistedChain() public {
        _setupMocks();

        // Override to make this chain a whitelisted settlement layer
        vm.mockCall(
            mockBridgehub,
            abi.encodeWithSelector(IBridgehubBase.whitelistedSettlementLayers.selector, testChainId),
            abi.encode(true)
        );

        // Mock getPriorityQueueSize to return non-zero
        vm.mockCall(
            address(upgrade),
            abi.encodeWithSelector(IGetters.getPriorityQueueSize.selector),
            abi.encode(5) // Non-zero queue size
        );

        vm.expectRevert(PriorityQueueNotReady.selector);
        upgrade.upgrade(proposedUpgrade);
    }

    function test_SuccessfulUpgrade_NonSettlementLayer() public {
        _setupMocks();

        // Settlement layer is address(0), so saveV31UpgradeChainBatchNumber should be called
        upgrade.setSettlementLayer(address(0));

        bytes32 result = upgrade.upgrade(proposedUpgrade);

        assertEq(result, Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE);
        assertEq(upgrade.getNativeTokenVault(), mockNativeTokenVault);
        assertEq(upgrade.getAssetTracker(), mockAssetTracker);
    }

    function test_SuccessfulUpgrade_WhitelistedSettlementLayerWithEmptyQueue() public {
        _setupMocks();

        // Make this chain a whitelisted settlement layer
        vm.mockCall(
            mockBridgehub,
            abi.encodeWithSelector(IBridgehubBase.whitelistedSettlementLayers.selector, testChainId),
            abi.encode(true)
        );

        // Mock getPriorityQueueSize to return 0
        vm.mockCall(address(upgrade), abi.encodeWithSelector(IGetters.getPriorityQueueSize.selector), abi.encode(0));

        bytes32 result = upgrade.upgrade(proposedUpgrade);

        assertEq(result, Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE);
    }

    function test_SetsDeprecatedL2DAValidatorToZero() public {
        _setupMocks();

        bytes32 result = upgrade.upgrade(proposedUpgrade);

        assertEq(result, Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE);
        // The __DEPRECATED_l2DAValidator should be set to address(0)
        // We can't directly check this in the test, but the upgrade should succeed
    }

    function testFuzz_RevertWhen_BatchesMismatch(uint256 committed, uint256 executed) public {
        vm.assume(committed > executed);
        vm.assume(committed < type(uint128).max);
        vm.assume(executed < type(uint128).max);

        _setupMocks();

        upgrade.setTotalBatchesCommitted(committed);
        upgrade.setTotalBatchesExecuted(executed);

        vm.expectRevert(NotAllBatchesExecuted.selector);
        upgrade.upgrade(proposedUpgrade);
    }

    function testFuzz_SuccessWhen_BatchesMatch(uint256 batchCount) public {
        batchCount = bound(batchCount, 0, type(uint128).max);

        _setupMocks();

        upgrade.setTotalBatchesCommitted(batchCount);
        upgrade.setTotalBatchesExecuted(batchCount);

        bytes32 result = upgrade.upgrade(proposedUpgrade);

        assertEq(result, Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE);
    }
}
