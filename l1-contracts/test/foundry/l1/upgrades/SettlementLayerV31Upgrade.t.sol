// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {EraSettlementLayerV31Upgrade} from "contracts/upgrades/EraSettlementLayerV31Upgrade.sol";
import {PriorityQueueNotReady} from "contracts/common/L1ContractErrors.sol";
import {NotAllBatchesExecuted} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {ProposedUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {BaseUpgrade} from "./_SharedBaseUpgrade.t.sol";
import {BaseUpgradeUtils} from "./_SharedBaseUpgradeUtils.t.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {IMessageRootBase} from "contracts/core/message-root/IMessageRoot.sol";

import {IL1MessageRoot} from "contracts/core/message-root/IL1MessageRoot.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";
import {ZKsyncOSSettlementLayerV31Upgrade} from "contracts/upgrades/ZKsyncOSSettlementLayerV31Upgrade.sol";
import {IL2V31Upgrade} from "contracts/upgrades/IL2V31Upgrade.sol";
import {ZKChainSpecificForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {TokenBridgingData, TokenMetadata} from "contracts/common/Messaging.sol";
import {
    L2_COMPLEX_UPGRADER_ADDR,
    L2_VERSION_SPECIFIC_UPGRADER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {L2UpgradeTxLib} from "contracts/upgrades/L2UpgradeTxLib.sol";

contract DummySettlementLayerV31Upgrade is EraSettlementLayerV31Upgrade, BaseUpgradeUtils {
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

    function getL2SystemContractsUpgradeTxHash() public view returns (bytes32) {
        return s.l2SystemContractsUpgradeTxHash;
    }

    function getConstructedCalldata(
        address _bridgehub,
        uint256 _chainId,
        bool _zksyncOS,
        bytes memory _existingUpgradeCalldata
    ) public view returns (bytes memory) {
        return L2UpgradeTxLib.buildL2V31UpgradeCalldata(_bridgehub, _chainId, _zksyncOS, _existingUpgradeCalldata);
    }

    function exposeBuildChainSpecificForceDeploymentsData(
        address _bridgehub,
        uint256 _chainId
    ) public view returns (bytes memory) {
        return L2UpgradeTxLib.buildChainSpecificForceDeploymentsData(_bridgehub, _chainId);
    }

    function setChainTypeManager(address _chainTypeManager) public override {
        s.chainTypeManager = _chainTypeManager;
    }
}

abstract contract SettlementLayerV31UpgradeTestBase is BaseUpgrade {
    DummySettlementLayerV31Upgrade internal upgrade;

    address internal mockBridgehub;
    address internal mockAssetRouter;
    address internal mockNativeTokenVault;
    address internal mockAssetTracker;
    address internal mockMessageRoot;
    address internal mockChainAssetHandler;
    address internal mockGWChain;
    address internal mockChainTypeManager = makeAddr("mockChainTypeManager");
    address internal mockVerifier = makeAddr("mockVerifier");

    uint256 internal testChainId = 123;
    uint256 internal gwChainId = 456;
    bytes32 internal baseTokenAssetId = keccak256("baseTokenAssetId");

    function _prepareV31ProposedUpgrade() internal {
        _prepareProposedUpgrade();
        proposedUpgrade.l2ProtocolUpgradeTx.to = uint256(uint160(L2_COMPLEX_UPGRADER_ADDR));

        // Era format: forceDeployAndUpgrade(ForceDeployment[], delegateTo, calldata)
        IL2ContractDeployer.ForceDeployment[] memory emptyDeployments = new IL2ContractDeployer.ForceDeployment[](0);
        proposedUpgrade.l2ProtocolUpgradeTx.data = abi.encodeCall(
            IComplexUpgrader.forceDeployAndUpgrade,
            (emptyDeployments, L2_VERSION_SPECIFIC_UPGRADER_ADDR, _placeholderV31Calldata())
        );
    }

    function setUp() public {
        mockBridgehub = makeAddr("bridgehub");
        mockAssetRouter = makeAddr("assetRouter");
        mockNativeTokenVault = makeAddr("nativeTokenVault");
        mockAssetTracker = makeAddr("assetTracker");
        mockMessageRoot = makeAddr("messageRoot");
        mockChainAssetHandler = makeAddr("chainAssetHandler");
        mockGWChain = makeAddr("gwChain");
        mockChainTypeManager = makeAddr("chainTypeManager");

        upgrade = new DummySettlementLayerV31Upgrade();
        upgrade.setBridgehub(mockBridgehub);
        upgrade.setChainId(testChainId);
        upgrade.setChainTypeManager(mockChainTypeManager);
        upgrade.setTotalBatchesCommitted(100);
        upgrade.setTotalBatchesExecuted(100);
        upgrade.setPriorityTxMaxGasLimit(1 ether);
        upgrade.setPriorityTxMaxPubdata(1000000);

        _prepareV31ProposedUpgrade();

        // Set up CTM for verifier lookup
        upgrade.setChainTypeManager(mockChainTypeManager);
        upgrade.mockProtocolVersionVerifier(protocolVersion, mockVerifier);
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
            abi.encodeWithSelector(IMessageRootBase.ERA_GATEWAY_CHAIN_ID.selector),
            abi.encode(gwChainId)
        );

        // Mock bridgehub.getZKChain
        vm.mockCall(
            mockBridgehub,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, gwChainId),
            abi.encode(mockGWChain)
        );

        // Mock bridgehub.getZKChain for testChainId — the upgrade contract reads
        // getZKsyncOS() from the diamond proxy to avoid relying on s.zksyncOS
        // (which is empty when getL2UpgradeTxData is called directly, not via delegatecall).
        vm.mockCall(
            mockBridgehub,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, testChainId),
            abi.encode(address(upgrade))
        );
        vm.mockCall(
            address(upgrade),
            abi.encodeWithSelector(IGetters.getZKsyncOS.selector),
            abi.encode(false)
        );

        // Mock gwChain.getSemverProtocolVersion - returns version >= 30
        vm.mockCall(
            mockGWChain,
            abi.encodeWithSelector(IGetters.getSemverProtocolVersion.selector),
            abi.encode(uint32(0), uint32(31), uint32(0)) // major=0, minor=31, patch=0
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

        // Mock chainTypeManager.PERMISSIONLESS_VALIDATOR
        vm.mockCall(
            mockChainTypeManager,
            abi.encodeWithSelector(IChainTypeManager.PERMISSIONLESS_VALIDATOR.selector),
            abi.encode(makeAddr("permissionlessValidator"))
        );
    }

    function _placeholderV31Calldata() internal pure returns (bytes memory) {
        return abi.encodeCall(IL2V31Upgrade.upgrade, (false, address(0), "", ""));
    }

    function _expectedV31Calldata() internal view returns (bytes memory) {
        // The rewrite preserves isZKsyncOS, ctmDeployer, fixedForceDeploymentsData from
        // the placeholder and replaces additionalForceDeploymentsData with chain-specific data.
        return
            abi.encodeCall(
                IL2V31Upgrade.upgrade,
                (
                    false,
                    address(0),
                    "",
                    upgrade.exposeBuildChainSpecificForceDeploymentsData(mockBridgehub, testChainId)
                )
            );
    }

    function _assertUpgradeRewritesTx(bytes memory originalUpgradeTxData) internal {
        bytes memory expectedUpgradeTxData = upgrade.getL2UpgradeTxData(
            mockBridgehub,
            testChainId,
            false,
            originalUpgradeTxData
        );
        proposedUpgrade.l2ProtocolUpgradeTx.data = expectedUpgradeTxData;
        bytes32 expectedTxHash = keccak256(abi.encode(proposedUpgrade.l2ProtocolUpgradeTx));

        proposedUpgrade.l2ProtocolUpgradeTx.data = originalUpgradeTxData;
        upgrade.upgrade(proposedUpgrade);

        assertEq(upgrade.getL2SystemContractsUpgradeTxHash(), expectedTxHash);
    }
}

contract SettlementLayerV31UpgradeSharedTest is SettlementLayerV31UpgradeTestBase {
    function test_RevertWhen_NotAllBatchesExecuted() public {
        _setupMocks();

        // Set batches committed > executed
        upgrade.setTotalBatchesCommitted(100);
        upgrade.setTotalBatchesExecuted(50);

        vm.expectRevert(NotAllBatchesExecuted.selector);
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

    function test_ConstructsChainSpecificL2V31UpgradeCalldata() public {
        _setupMocks();

        bytes memory data =
            upgrade.getConstructedCalldata(mockBridgehub, testChainId, false, _placeholderV31Calldata());

        assertEq(data, _expectedV31Calldata());
    }

    function test_BuildsChainSpecificForceDeploymentsData_UsesLocalTokenMetadataForBridgedBaseToken() public {
        _setupMocks();

        uint256 originChainId = 999;
        address originToken = makeAddr("originToken");
        address localToken = makeAddr("localToken");
        string memory expectedName = "Bridged Token";
        string memory expectedSymbol = "BTKN";
        uint8 expectedDecimals = 6;

        vm.mockCall(
            mockNativeTokenVault,
            abi.encodeWithSelector(INativeTokenVaultBase.originChainId.selector, baseTokenAssetId),
            abi.encode(originChainId)
        );
        vm.mockCall(
            mockNativeTokenVault,
            abi.encodeWithSelector(INativeTokenVaultBase.originToken.selector, baseTokenAssetId),
            abi.encode(originToken)
        );
        vm.mockCall(
            mockNativeTokenVault,
            abi.encodeWithSelector(INativeTokenVaultBase.tokenAddress.selector, baseTokenAssetId),
            abi.encode(localToken)
        );

        vm.mockCall(localToken, abi.encodeWithSignature("name()"), abi.encode(expectedName));
        vm.mockCall(localToken, abi.encodeWithSignature("symbol()"), abi.encode(expectedSymbol));
        vm.mockCall(localToken, abi.encodeWithSignature("decimals()"), abi.encode(expectedDecimals));

        bytes memory forceDeploymentsData = upgrade.exposeBuildChainSpecificForceDeploymentsData(
            mockBridgehub,
            testChainId
        );

        ZKChainSpecificForceDeploymentsData memory decoded = abi.decode(
            forceDeploymentsData,
            (ZKChainSpecificForceDeploymentsData)
        );

        assertEq(decoded.baseTokenL1Address, originToken);
        assertEq(decoded.baseTokenMetadata.name, expectedName);
        assertEq(decoded.baseTokenMetadata.symbol, expectedSymbol);
        assertEq(decoded.baseTokenMetadata.decimals, expectedDecimals);
        assertEq(decoded.baseTokenBridgingData.assetId, baseTokenAssetId);
        assertEq(decoded.baseTokenBridgingData.originChainId, originChainId);
        assertEq(decoded.baseTokenBridgingData.originToken, originToken);
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

contract SettlementLayerV31UpgradeEraV29Test is SettlementLayerV31UpgradeTestBase {
    function test_RewritesEraV29ForceDeployAndUpgradeWithChainSpecificV31Arguments() public {
        _setupMocks();
        _prepareV31ProposedUpgrade();

        IL2ContractDeployer.ForceDeployment[] memory forceDeployments = new IL2ContractDeployer.ForceDeployment[](1);
        forceDeployments[0] = IL2ContractDeployer.ForceDeployment({
            bytecodeHash: keccak256("bytecode"),
            newAddress: makeAddr("newAddress"),
            callConstructor: false,
            value: 0,
            input: hex""
        });

        bytes memory originalV31Calldata = _placeholderV31Calldata();
        bytes memory originalUpgradeTxData = abi.encodeCall(
            IComplexUpgrader.forceDeployAndUpgrade,
            (forceDeployments, L2_VERSION_SPECIFIC_UPGRADER_ADDR, originalV31Calldata)
        );

        bytes memory expectedUpgradeTxData = abi.encodeCall(
            IComplexUpgrader.forceDeployAndUpgrade,
            (forceDeployments, L2_VERSION_SPECIFIC_UPGRADER_ADDR, _expectedV31Calldata())
        );

        assertEq(
            upgrade.getL2UpgradeTxData(mockBridgehub, testChainId, false, originalUpgradeTxData),
            expectedUpgradeTxData
        );
        _assertUpgradeRewritesTx(originalUpgradeTxData);
    }
}

contract DummyZKsyncOSSettlementLayerV31Upgrade is ZKsyncOSSettlementLayerV31Upgrade, BaseUpgradeUtils {
    function setBridgehub(address _bridgehub) public {
        s.bridgehub = _bridgehub;
    }

    function setChainId(uint256 _chainId) public {
        s.chainId = _chainId;
    }

    function setZksyncOS(bool _v) public {
        s.zksyncOS = _v;
    }

    function setTotalBatchesCommitted(uint256 _v) public {
        s.totalBatchesCommitted = _v;
    }

    function setTotalBatchesExecuted(uint256 _v) public {
        s.totalBatchesExecuted = _v;
    }

    function setChainTypeManager(address _ctm) public override {
        s.chainTypeManager = _ctm;
    }

    function exposeBuildChainSpecificForceDeploymentsData(
        address _bridgehub,
        uint256 _chainId
    ) public view returns (bytes memory) {
        return L2UpgradeTxLib.buildChainSpecificForceDeploymentsData(_bridgehub, _chainId);
    }
}

contract SettlementLayerV31UpgradeZKsyncOSV30Test is BaseUpgrade {
    DummyZKsyncOSSettlementLayerV31Upgrade internal zkosUpgrade;

    address internal mockBridgehub;
    address internal mockAssetRouter;
    address internal mockNativeTokenVault;
    address internal mockAssetTracker;
    address internal mockMessageRoot;
    address internal mockChainTypeManager;
    address internal mockVerifier = makeAddr("mockVerifier");
    uint256 internal testChainId = 123;
    bytes32 internal baseTokenAssetId = keccak256("baseTokenAssetId");

    function setUp() public {
        mockBridgehub = makeAddr("bridgehub");
        mockAssetRouter = makeAddr("assetRouter");
        mockNativeTokenVault = makeAddr("nativeTokenVault");
        mockAssetTracker = makeAddr("assetTracker");
        mockMessageRoot = makeAddr("messageRoot");
        mockChainTypeManager = makeAddr("chainTypeManager");

        zkosUpgrade = new DummyZKsyncOSSettlementLayerV31Upgrade();
        zkosUpgrade.setBridgehub(mockBridgehub);
        zkosUpgrade.setChainId(testChainId);
        zkosUpgrade.setZksyncOS(true);
        zkosUpgrade.setChainTypeManager(mockChainTypeManager);
        zkosUpgrade.setTotalBatchesCommitted(100);
        zkosUpgrade.setTotalBatchesExecuted(100);
        zkosUpgrade.setPriorityTxMaxGasLimit(1 ether);
        zkosUpgrade.setPriorityTxMaxPubdata(1000000);
        zkosUpgrade.mockProtocolVersionVerifier(protocolVersion, mockVerifier);

        _setupMocks();
    }

    function _setupMocks() internal {
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
            mockNativeTokenVault,
            abi.encodeWithSelector(IL1NativeTokenVault.l1AssetTracker.selector),
            abi.encode(mockAssetTracker)
        );
        vm.mockCall(
            mockBridgehub,
            abi.encodeWithSelector(IBridgehubBase.baseTokenAssetId.selector, testChainId),
            abi.encode(baseTokenAssetId)
        );
        vm.mockCall(
            mockNativeTokenVault,
            abi.encodeWithSelector(INativeTokenVaultBase.originChainId.selector, baseTokenAssetId),
            abi.encode(block.chainid)
        );
        vm.mockCall(
            mockNativeTokenVault,
            abi.encodeWithSelector(INativeTokenVaultBase.originToken.selector, baseTokenAssetId),
            abi.encode(address(1))
        );
        vm.mockCall(
            mockBridgehub,
            abi.encodeWithSelector(IBridgehubBase.messageRoot.selector),
            abi.encode(mockMessageRoot)
        );
        vm.mockCall(
            mockMessageRoot,
            abi.encodeWithSelector(IL1MessageRoot.saveV31UpgradeChainBatchNumber.selector, testChainId),
            abi.encode()
        );
        vm.mockCall(
            mockBridgehub,
            abi.encodeWithSelector(IBridgehubBase.whitelistedSettlementLayers.selector, testChainId),
            abi.encode(false)
        );
        vm.mockCall(
            mockChainTypeManager,
            abi.encodeWithSelector(IChainTypeManager.PERMISSIONLESS_VALIDATOR.selector),
            abi.encode(makeAddr("permissionlessValidator"))
        );

        // Mock bridgehub.getZKChain for testChainId and getZKsyncOS on the diamond proxy.
        vm.mockCall(
            mockBridgehub,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, testChainId),
            abi.encode(address(zkosUpgrade))
        );
        vm.mockCall(
            address(zkosUpgrade),
            abi.encodeWithSelector(IGetters.getZKsyncOS.selector),
            abi.encode(true)
        );
    }

    function test_RewritesZKsyncOSV30UniversalUpgradeWithChainSpecificV31Arguments() public {
        IComplexUpgrader.UniversalContractUpgradeInfo[]
            memory forceDeployments = new IComplexUpgrader.UniversalContractUpgradeInfo[](1);
        forceDeployments[0] = IComplexUpgrader.UniversalContractUpgradeInfo({
            upgradeType: IComplexUpgrader.ContractUpgradeType.ZKsyncOSUnsafeForceDeployment,
            deployedBytecodeInfo: abi.encode(bytes32(uint256(1)), uint32(1), bytes32(uint256(2))),
            newAddress: makeAddr("newAddress")
        });

        bytes memory placeholderCalldata = abi.encodeCall(IL2V31Upgrade.upgrade, (true, address(0), "", ""));
        bytes memory originalUpgradeTxData = abi.encodeCall(
            IComplexUpgrader.forceDeployAndUpgradeUniversal,
            (forceDeployments, L2_VERSION_SPECIFIC_UPGRADER_ADDR, placeholderCalldata)
        );

        bytes memory expectedInnerCalldata = abi.encodeCall(
            IL2V31Upgrade.upgrade,
            (true, address(0), "", zkosUpgrade.exposeBuildChainSpecificForceDeploymentsData(mockBridgehub, testChainId))
        );
        bytes memory expectedUpgradeTxData = abi.encodeCall(
            IComplexUpgrader.forceDeployAndUpgradeUniversal,
            (forceDeployments, L2_VERSION_SPECIFIC_UPGRADER_ADDR, expectedInnerCalldata)
        );

        assertEq(
            zkosUpgrade.getL2UpgradeTxData(mockBridgehub, testChainId, true, originalUpgradeTxData),
            expectedUpgradeTxData
        );
    }
}
