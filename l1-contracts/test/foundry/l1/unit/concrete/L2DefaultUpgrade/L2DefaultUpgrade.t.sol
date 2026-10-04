// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {
    L2_ASSET_ROUTER_ADDR,
    L2_ASSET_TRACKER_ADDR,
    L2_ATOMIC_FLOW_MANAGER_ADDR,
    L2_INTEROP_COMMITMENT_TREE_ADDR,
    L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
    L2_BRIDGEHUB_ADDR,
    L2_CHAIN_ASSET_HANDLER_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_DEPLOYER_SYSTEM_CONTRACT_ADDR,
    L2_FORCE_DEPLOYER_ADDR,
    L2_INTEROP_CENTER_ADDR,
    L2_INTEROP_HANDLER_ADDR,
    INTEROP_COMMITMENT_LEAF_HOOK,
    L2_MESSAGE_ROOT_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {L2ComplexUpgrader} from "contracts/l2-upgrades/L2ComplexUpgrader.sol";
import {L2MessageRoot} from "contracts/core/message-root/L2MessageRoot.sol";
import {L2Bridgehub} from "contracts/core/bridgehub/L2Bridgehub.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {L2ChainAssetHandler} from "contracts/core/chain-asset-handler/L2ChainAssetHandler.sol";
import {L2DefaultUpgrade} from "contracts/l2-upgrades/L2DefaultUpgrade.sol";
import {L2InteropCommitmentTree} from "contracts/atomic-interop/L2InteropCommitmentTree.sol";
import {AtomicFlowManager} from "contracts/atomic-interop/AtomicFlowManager.sol";
import {IL2DefaultUpgrade} from "contracts/upgrades/IL2DefaultUpgrade.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {TokenBridgingData, TokenMetadata} from "contracts/common/Messaging.sol";
import {
    FixedForceDeploymentsData,
    ZKChainSpecificForceDeploymentsData
} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";

/// @dev A mock that accepts any call and returns 32 zero bytes (used for contracts where
/// we don't verify behavior but callers decode return data).
contract MockAcceptAll {
    fallback() external payable {
        assembly {
            mstore(0x00, 0)
            return(0x00, 0x20)
        }
    }
}

/// @dev Mock NTV that records updateL2 calls for verification.
contract MockL2DefaultUpgradeNativeTokenVault {
    bytes32 public immutable BASE_TOKEN_ASSET_ID;
    uint256 public immutable L1_CHAIN_ID;
    address public immutable WETH_TOKEN;

    address public BASE_TOKEN_ORIGIN_TOKEN;
    string public BASE_TOKEN_NAME;
    string public BASE_TOKEN_SYMBOL;
    uint256 public BASE_TOKEN_DECIMALS;

    uint256 public lastOriginChainId;
    uint256 public updateCalls;

    mapping(bytes32 assetId => uint256 originChainIdValue) private _originChainId;

    constructor(bytes32 _assetId, uint256 _l1ChainId, address _wethToken) {
        BASE_TOKEN_ASSET_ID = _assetId;
        L1_CHAIN_ID = _l1ChainId;
        WETH_TOKEN = _wethToken;
        BASE_TOKEN_NAME = "Ether";
        BASE_TOKEN_SYMBOL = "ETH";
        BASE_TOKEN_DECIMALS = 18;
    }

    function originChainId(bytes32 _assetId) external view returns (uint256) {
        return _originChainId[_assetId];
    }

    function originToken(bytes32 _assetId) external view returns (address) {
        if (_assetId == BASE_TOKEN_ASSET_ID) {
            return BASE_TOKEN_ORIGIN_TOKEN;
        }
        return address(0);
    }

    function registerBaseTokenIfNeeded() external {
        // No-op for mock
    }

    function updateL2(
        uint256 _l1ChainId,
        address /* _aliasedOwner */,
        address _wethToken,
        TokenBridgingData calldata _baseTokenBridgingData,
        TokenMetadata calldata _baseTokenMetadata
    ) external {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert Unauthorized(msg.sender);
        }

        require(_l1ChainId == L1_CHAIN_ID, "unexpected L1 chain id");
        require(_wethToken == WETH_TOKEN, "unexpected weth token");
        require(_baseTokenBridgingData.assetId == BASE_TOKEN_ASSET_ID, "unexpected base token asset id");

        BASE_TOKEN_ORIGIN_TOKEN = _baseTokenBridgingData.originToken;
        BASE_TOKEN_NAME = _baseTokenMetadata.name;
        BASE_TOKEN_SYMBOL = _baseTokenMetadata.symbol;
        BASE_TOKEN_DECIMALS = _baseTokenMetadata.decimals;
        _originChainId[_baseTokenBridgingData.assetId] = _baseTokenBridgingData.originChainId;
        lastOriginChainId = _baseTokenBridgingData.originChainId;
        updateCalls++;
    }
}

/// @dev Mock AssetTracker that records initL2 calls.
contract MockL2DefaultUpgradeAssetTracker {
    uint256 public L1_CHAIN_ID;
    bytes32 public BASE_TOKEN_ASSET_ID;

    uint256 public initCalls;

    function initL2(uint256 _l1ChainId, bytes32 _baseTokenAssetId) external {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert Unauthorized(msg.sender);
        }

        L1_CHAIN_ID = _l1ChainId;
        BASE_TOKEN_ASSET_ID = _baseTokenAssetId;
        initCalls++;
    }
}

/// @dev Mock BaseToken that records initL2 calls.
contract MockL2DefaultUpgradeBaseToken {
    uint256 public initCalls;
    uint256 public lastInitializedL1ChainId;

    function initL2(uint256 _l1ChainId) external {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert Unauthorized(msg.sender);
        }

        initCalls++;
        lastInitializedL1ChainId = _l1ChainId;
    }
}

contract L2DefaultUpgradeUnitTest is Test {
    bytes32 internal constant BASE_TOKEN_ASSET_ID = keccak256("base-token");
    uint256 internal constant L1_CHAIN_ID = 9;
    uint256 internal constant GATEWAY_CHAIN_ID = 0;
    uint256 internal constant MAX_NUMBER_OF_ZKCHAINS = 100;
    uint256 internal constant BASE_TOKEN_ORIGIN_CHAIN_ID = 1;
    address internal constant BASE_TOKEN_ORIGIN_ADDRESS = address(0x1234);
    address internal constant BASE_TOKEN_L1_ADDRESS = address(0x5678);
    address internal constant L1_ASSET_ROUTER = address(0xAA01);
    address internal constant ALIASED_L1_GOVERNANCE = address(0xAA02);
    address internal constant ALIASED_CHAIN_REGISTRATION_SENDER = address(0xAA03);
    address internal constant CTM_DEPLOYER = address(0xAA04);
    address internal constant PREDEPLOYED_WETH = address(0xdead);
    uint256 internal constant COMMITTED_VALUE = 42;

    L2DefaultUpgrade internal testUpgrade;

    function setUp() public {
        // Deploy ComplexUpgrader
        bytes memory complexUpgraderBytecode = vm.getDeployedCode("L2ComplexUpgrader.sol:L2ComplexUpgrader");
        vm.etch(L2_COMPLEX_UPGRADER_ADDR, complexUpgraderBytecode);

        // AcceptAll mock for contracts where we don't verify behavior
        MockAcceptAll acceptAll = new MockAcceptAll();
        address[] memory acceptAllAddresses = new address[](8);
        acceptAllAddresses[0] = L2_DEPLOYER_SYSTEM_CONTRACT_ADDR;
        acceptAllAddresses[1] = L2_MESSAGE_ROOT_ADDR;
        acceptAllAddresses[2] = L2_BRIDGEHUB_ADDR;
        acceptAllAddresses[3] = L2_ASSET_ROUTER_ADDR;
        acceptAllAddresses[4] = L2_CHAIN_ASSET_HANDLER_ADDR;
        acceptAllAddresses[5] = L2_INTEROP_CENTER_ADDR;
        acceptAllAddresses[6] = L2_INTEROP_HANDLER_ADDR;
        acceptAllAddresses[7] = L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR;
        for (uint256 i = 0; i < acceptAllAddresses.length; i++) {
            vm.etch(acceptAllAddresses[i], address(acceptAll).code);
        }

        // Specific mocks for contracts we verify
        _etchCode(
            L2_NATIVE_TOKEN_VAULT_ADDR,
            address(new MockL2DefaultUpgradeNativeTokenVault(BASE_TOKEN_ASSET_ID, L1_CHAIN_ID, PREDEPLOYED_WETH))
        );
        _etchCode(L2_ASSET_TRACKER_ADDR, address(new MockL2DefaultUpgradeAssetTracker()));
        _etchCode(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, address(new MockL2DefaultUpgradeBaseToken()));

        // The atomic-interop built-ins get their real code, so their initialization is observable.
        vm.etch(L2_INTEROP_COMMITMENT_TREE_ADDR, address(new L2InteropCommitmentTree()).code);
        vm.etch(L2_ATOMIC_FLOW_MANAGER_ADDR, address(new AtomicFlowManager()).code);

        testUpgrade = new L2DefaultUpgrade();
    }

    /// @dev The contracts introduced in v31 are initialized on the genesis path only: their `initL2`s are
    /// unchanged since v31 and one-shot, so a chain that already went through v31 must not run them again.
    /// This upgrade therefore leaves the asset tracker and the base token alone; what it does run for them
    /// is covered by `L2GenesisForceDeploymentHelper.t.sol`.
    function test_UpgradeViaComplexUpgrader_LeavesPreV32ContractsAlone() public {
        _runUpgrade();

        // AssetTracker: not re-initialized.
        MockL2DefaultUpgradeAssetTracker assetTracker = MockL2DefaultUpgradeAssetTracker(L2_ASSET_TRACKER_ADDR);
        assertEq(assetTracker.initCalls(), 0, "asset tracker must not be re-initialized on an upgrade");

        // Verify NTV: updateL2 called with correct data
        MockL2DefaultUpgradeNativeTokenVault nativeTokenVault = MockL2DefaultUpgradeNativeTokenVault(
            L2_NATIVE_TOKEN_VAULT_ADDR
        );
        assertEq(nativeTokenVault.updateCalls(), 1, "native token vault should be updated exactly once");
        assertEq(nativeTokenVault.lastOriginChainId(), BASE_TOKEN_ORIGIN_CHAIN_ID, "origin chain id mismatch");
        assertEq(nativeTokenVault.BASE_TOKEN_ORIGIN_TOKEN(), BASE_TOKEN_ORIGIN_ADDRESS, "origin token mismatch");

        // BaseToken: its `initL2` is a genesis-path call as well.
        MockL2DefaultUpgradeBaseToken baseToken = MockL2DefaultUpgradeBaseToken(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        assertEq(baseToken.initCalls(), 0, "base token must not be re-initialized on an upgrade");
    }

    /// @dev The atomic-interop built-ins are initialized at genesis only: every chain this upgrade applies to
    /// already runs them initialized, so the upgrade must not call their one-shot `initL2`s.
    function test_UpgradeViaComplexUpgrader_LeavesAtomicInteropBuiltInsAlone() public {
        _runUpgrade();

        assertEq(L2InteropCommitmentTree(L2_INTEROP_COMMITMENT_TREE_ADDR).leafCount(), 0, "tree must not be seeded");
        assertEq(
            AtomicFlowManager(L2_ATOMIC_FLOW_MANAGER_ADDR).L1_CHAIN_ID(),
            0,
            "flow manager must not be initialized"
        );
    }

    /// @dev Every later release reuses this upgrade, so it must be repeatable on a chain whose built-ins genesis
    /// initialized (their `initL2`s revert with `IMTAlreadyInitialized` / `ManagerAlreadyInitialized`). The
    /// contracts the upgrade path re-calls (`updateL2` / `setAddresses`) run their real code here, so one of
    /// them turning one-shot would fail the second run.
    function test_UpgradeViaComplexUpgrader_IsRepeatable() public {
        _initAtomicInteropBuiltInsAsGenesis();
        vm.etch(L2_MESSAGE_ROOT_ADDR, address(new L2MessageRoot()).code);
        vm.etch(L2_BRIDGEHUB_ADDR, address(new L2Bridgehub()).code);
        vm.etch(L2_ASSET_ROUTER_ADDR, address(new L2AssetRouter()).code);
        vm.etch(L2_CHAIN_ASSET_HANDLER_ADDR, address(new L2ChainAssetHandler()).code);

        _runUpgrade();

        // Real activity between the upgrades: the tree holds more than its sentinel leaf.
        vm.etch(INTEROP_COMMITMENT_LEAF_HOOK, address(new MockAcceptAll()).code);
        L2InteropCommitmentTree tree = L2InteropCommitmentTree(L2_INTEROP_COMMITMENT_TREE_ADDR);
        vm.prank(tree.appender());
        tree.insert(COMMITTED_VALUE, 0);
        bytes32 rootBefore = tree.root();

        _runUpgrade();

        assertEq(tree.leafCount(), 2, "the commitment tree must not be re-seeded");
        assertEq(tree.root(), rootBefore, "the commitment tree root must be preserved");
        assertEq(tree.leafAt(1).value, COMMITTED_VALUE, "the inserted leaf must be preserved");
        assertEq(AtomicFlowManager(L2_ATOMIC_FLOW_MANAGER_ADDR).L1_CHAIN_ID(), L1_CHAIN_ID, "l1 chain id changed");
        assertEq(
            MockL2DefaultUpgradeNativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).updateCalls(),
            2,
            "the native token vault must be updated on every upgrade"
        );

        assertEq(L2MessageRoot(L2_MESSAGE_ROOT_ADDR).L1_CHAIN_ID(), L1_CHAIN_ID, "message root l1 chain id");
        L2Bridgehub bridgehub = L2Bridgehub(L2_BRIDGEHUB_ADDR);
        assertEq(bridgehub.L1_CHAIN_ID(), L1_CHAIN_ID, "bridgehub l1 chain id");
        assertEq(bridgehub.owner(), ALIASED_L1_GOVERNANCE, "bridgehub owner");
        assertEq(address(bridgehub.assetRouter()), L2_ASSET_ROUTER_ADDR, "bridgehub asset router");
        assertEq(address(bridgehub.l1CtmDeployer()), CTM_DEPLOYER, "bridgehub ctm deployer");
        L2AssetRouter assetRouter = L2AssetRouter(L2_ASSET_ROUTER_ADDR);
        assertEq(address(assetRouter.L1_ASSET_ROUTER()), L1_ASSET_ROUTER, "asset router l1 counterpart");
        assertEq(assetRouter.BASE_TOKEN_ASSET_ID(), BASE_TOKEN_ASSET_ID, "asset router base token");
        assertEq(assetRouter.owner(), ALIASED_L1_GOVERNANCE, "asset router owner");
        assertEq(
            L2ChainAssetHandler(L2_CHAIN_ASSET_HANDLER_ADDR).owner(),
            ALIASED_L1_GOVERNANCE,
            "chain asset handler owner"
        );
    }

    /// @dev Genesis state of the atomic-interop built-ins, as `L2GenesisUpgrade` leaves it.
    function _initAtomicInteropBuiltInsAsGenesis() private {
        vm.startPrank(L2_COMPLEX_UPGRADER_ADDR);
        L2InteropCommitmentTree(L2_INTEROP_COMMITMENT_TREE_ADDR).initL2();
        AtomicFlowManager(L2_ATOMIC_FLOW_MANAGER_ADDR).initL2(L1_CHAIN_ID);
        vm.stopPrank();
    }

    function _runUpgrade() private {
        bytes memory fixedData = abi.encode(_buildFixedForceDeploymentsData());
        bytes memory additionalData = abi.encode(_buildZKChainSpecificData());

        vm.prank(L2_FORCE_DEPLOYER_ADDR);
        L2ComplexUpgrader(L2_COMPLEX_UPGRADER_ADDR).upgrade(
            address(testUpgrade),
            abi.encodeCall(IL2DefaultUpgrade.upgrade, (CTM_DEPLOYER, fixedData, additionalData))
        );
    }

    function _buildFixedForceDeploymentsData() private pure returns (FixedForceDeploymentsData memory) {
        bytes memory dummyBytecodeInfo = abi.encode(bytes32(0));

        return
            FixedForceDeploymentsData({
                l1ChainId: L1_CHAIN_ID,
                l1AssetRouter: L1_ASSET_ROUTER,
                aliasedL1Governance: ALIASED_L1_GOVERNANCE,
                maxNumberOfZKChains: MAX_NUMBER_OF_ZKCHAINS,
                bridgehubBytecodeInfo: dummyBytecodeInfo,
                l2AssetRouterBytecodeInfo: dummyBytecodeInfo,
                l2NtvBytecodeInfo: dummyBytecodeInfo,
                messageRootBytecodeInfo: dummyBytecodeInfo,
                chainAssetHandlerBytecodeInfo: dummyBytecodeInfo,
                interopCenterBytecodeInfo: dummyBytecodeInfo,
                interopHandlerBytecodeInfo: dummyBytecodeInfo,
                assetTrackerBytecodeInfo: dummyBytecodeInfo,
                beaconDeployerInfo: dummyBytecodeInfo,
                baseTokenHolderBytecodeInfo: dummyBytecodeInfo,
                l2SharedBridgeLegacyImpl: address(0),
                l2BridgedStandardERC20Impl: address(0),
                aliasedChainRegistrationSender: ALIASED_CHAIN_REGISTRATION_SENDER,
                dangerousTestOnlyForcedBeacon: address(0),
                zkTokenAssetId: bytes32(0)
            });
    }

    function _buildZKChainSpecificData() private pure returns (ZKChainSpecificForceDeploymentsData memory) {
        return
            ZKChainSpecificForceDeploymentsData({
                l2LegacySharedBridge: address(0),
                predeployedL2WethAddress: PREDEPLOYED_WETH,
                baseTokenL1Address: BASE_TOKEN_L1_ADDRESS,
                baseTokenMetadata: TokenMetadata({name: "Ether", symbol: "ETH", decimals: 18}),
                baseTokenBridgingData: TokenBridgingData({
                    assetId: BASE_TOKEN_ASSET_ID,
                    originChainId: BASE_TOKEN_ORIGIN_CHAIN_ID,
                    originToken: BASE_TOKEN_ORIGIN_ADDRESS
                })
            });
    }

    function _etchCode(address _target, address _source) private {
        vm.etch(_target, _source.code);
    }
}
