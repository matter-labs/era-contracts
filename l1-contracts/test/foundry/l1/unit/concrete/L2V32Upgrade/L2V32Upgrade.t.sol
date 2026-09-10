// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {
    L2_ASSET_ROUTER_ADDR,
    L2_ASSET_TRACKER_ADDR,
    L2_ATOMIC_FLOW_MANAGER_ADDR,
    L2_INTEROP_COMMITMENT_TREE_ADDR,
    L2_BASE_TOKEN_HOLDER_ADDR,
    L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
    L2_BRIDGEHUB_ADDR,
    L2_CHAIN_ASSET_HANDLER_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_DEPLOYER_SYSTEM_CONTRACT_ADDR,
    L2_FORCE_DEPLOYER_ADDR,
    L2_INTEROP_CENTER_ADDR,
    L2_INTEROP_HANDLER_ADDR,
    L2_MESSAGE_ROOT_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR,
    L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {L2ComplexUpgrader} from "contracts/l2-upgrades/L2ComplexUpgrader.sol";
import {L2V32Upgrade} from "contracts/l2-upgrades/L2V32Upgrade.sol";
import {L2InteropCommitmentTree} from "contracts/atomic-interop/L2InteropCommitmentTree.sol";
import {AtomicFlowManager} from "contracts/atomic-interop/AtomicFlowManager.sol";
import {IL2V32Upgrade} from "contracts/upgrades/IL2V32Upgrade.sol";
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
contract MockV32UpgradeNativeTokenVault {
    bytes32 public immutable BASE_TOKEN_ASSET_ID;
    uint256 public immutable L1_CHAIN_ID;
    bytes32 public immutable L2_TOKEN_PROXY_BYTECODE_HASH;
    address public immutable WETH_TOKEN;

    address public BASE_TOKEN_ORIGIN_TOKEN;
    string public BASE_TOKEN_NAME;
    string public BASE_TOKEN_SYMBOL;
    uint256 public BASE_TOKEN_DECIMALS;

    uint256 public lastOriginChainId;
    uint256 public updateCalls;

    mapping(bytes32 assetId => uint256 originChainIdValue) private _originChainId;

    constructor(bytes32 _assetId, uint256 _l1ChainId, bytes32 _proxyBytecodeHash, address _wethToken) {
        BASE_TOKEN_ASSET_ID = _assetId;
        L1_CHAIN_ID = _l1ChainId;
        L2_TOKEN_PROXY_BYTECODE_HASH = _proxyBytecodeHash;
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
        bytes32 _l2TokenProxyBytecodeHash,
        address _wethToken,
        TokenBridgingData calldata _baseTokenBridgingData,
        TokenMetadata calldata _baseTokenMetadata
    ) external {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert Unauthorized(msg.sender);
        }

        require(_l1ChainId == L1_CHAIN_ID, "unexpected L1 chain id");
        require(_l2TokenProxyBytecodeHash == L2_TOKEN_PROXY_BYTECODE_HASH, "unexpected proxy bytecode hash");
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
contract MockV32UpgradeAssetTracker {
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
contract MockV32UpgradeBaseToken {
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

contract L2V32UpgradeUnitTest is Test {
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
    bytes32 internal constant L2_TOKEN_PROXY_BYTECODE_HASH = keccak256("proxy");

    L2V32Upgrade internal testUpgrade;

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
            address(
                new MockV32UpgradeNativeTokenVault(
                    BASE_TOKEN_ASSET_ID,
                    L1_CHAIN_ID,
                    L2_TOKEN_PROXY_BYTECODE_HASH,
                    PREDEPLOYED_WETH
                )
            )
        );
        _etchCode(L2_ASSET_TRACKER_ADDR, address(new MockV32UpgradeAssetTracker()));
        _etchCode(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, address(new MockV32UpgradeBaseToken()));

        testUpgrade = new L2V32Upgrade();
    }

    /// @dev The contracts introduced in v31 are initialized on the genesis path only: their `initL2`s are
    /// unchanged since v31 and one-shot, so a chain that already went through v31 must not run them again.
    /// This upgrade therefore leaves the asset tracker and the base token alone; what it does run for them
    /// is covered by `L2GenesisForceDeploymentHelper.t.sol`.
    function test_UpgradeViaComplexUpgrader_LeavesPreV32ContractsAlone() public {
        bytes memory fixedData = abi.encode(_buildFixedForceDeploymentsData());
        bytes memory additionalData = abi.encode(_buildZKChainSpecificData());

        vm.prank(L2_FORCE_DEPLOYER_ADDR);
        L2ComplexUpgrader(L2_COMPLEX_UPGRADER_ADDR).upgrade(
            address(testUpgrade),
            abi.encodeCall(IL2V32Upgrade.upgrade, (false, CTM_DEPLOYER, fixedData, additionalData))
        );

        // AssetTracker: not re-initialized.
        MockV32UpgradeAssetTracker assetTracker = MockV32UpgradeAssetTracker(L2_ASSET_TRACKER_ADDR);
        assertEq(assetTracker.initCalls(), 0, "asset tracker must not be re-initialized on an upgrade");

        // Verify NTV: updateL2 called with correct data
        MockV32UpgradeNativeTokenVault nativeTokenVault = MockV32UpgradeNativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);
        assertEq(nativeTokenVault.updateCalls(), 1, "native token vault should be updated exactly once");
        assertEq(nativeTokenVault.lastOriginChainId(), BASE_TOKEN_ORIGIN_CHAIN_ID, "origin chain id mismatch");
        assertEq(nativeTokenVault.BASE_TOKEN_ORIGIN_TOKEN(), BASE_TOKEN_ORIGIN_ADDRESS, "origin token mismatch");

        // BaseToken: its `initL2` is a genesis-path call as well.
        MockV32UpgradeBaseToken baseToken = MockV32UpgradeBaseToken(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        assertEq(baseToken.initCalls(), 0, "base token must not be re-initialized on an upgrade");
    }

    /// @dev The ZKsync OS path must forward `_isZKsyncOS == true` to the helper: the atomic-interop
    /// built-ins arrive with the upgrade's force deployments and are initialized here for the first
    /// time (the tree gets its sentinel leaf, the flow manager the L1 chain id).
    function test_UpgradeViaComplexUpgrader_ZKOSInitializesAtomicInteropBuiltIns() public {
        vm.etch(L2_INTEROP_COMMITMENT_TREE_ADDR, address(new L2InteropCommitmentTree()).code);
        vm.etch(L2_ATOMIC_FLOW_MANAGER_ADDR, address(new AtomicFlowManager()).code);

        bytes memory fixedData = abi.encode(_buildFixedForceDeploymentsData());
        bytes memory additionalData = abi.encode(_buildZKChainSpecificData());

        vm.prank(L2_FORCE_DEPLOYER_ADDR);
        L2ComplexUpgrader(L2_COMPLEX_UPGRADER_ADDR).upgrade(
            address(testUpgrade),
            abi.encodeCall(IL2V32Upgrade.upgrade, (true, CTM_DEPLOYER, fixedData, additionalData))
        );

        assertEq(
            L2InteropCommitmentTree(L2_INTEROP_COMMITMENT_TREE_ADDR).leafCount(),
            1,
            "the commitment tree must be seeded with its sentinel leaf"
        );
        assertEq(
            AtomicFlowManager(L2_ATOMIC_FLOW_MANAGER_ADDR).L1_CHAIN_ID(),
            L1_CHAIN_ID,
            "the flow manager must receive the L1 chain id"
        );

        // Pre-v32 contracts stay untouched on the ZKsync OS path too.
        MockV32UpgradeBaseToken baseToken = MockV32UpgradeBaseToken(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        assertEq(baseToken.initCalls(), 0, "base token must not be re-initialized on an upgrade");
    }

    function _buildFixedForceDeploymentsData() private pure returns (FixedForceDeploymentsData memory) {
        bytes memory dummyBytecodeInfo = abi.encode(bytes32(0));

        return
            FixedForceDeploymentsData({
                l1ChainId: L1_CHAIN_ID,
                l1AssetRouter: L1_ASSET_ROUTER,
                l2TokenProxyBytecodeHash: L2_TOKEN_PROXY_BYTECODE_HASH,
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
