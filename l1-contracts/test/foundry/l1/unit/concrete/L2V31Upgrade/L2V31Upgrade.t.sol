// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {
    GW_ASSET_TRACKER_ADDR,
    L2_ASSET_ROUTER_ADDR,
    L2_ASSET_TRACKER_ADDR,
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
import {AcrossInfo, LensSpokePoolConstructorParams} from "contracts/l2-upgrades/V31AcrossRecovery.sol";
import {L2V31Upgrade} from "contracts/l2-upgrades/L2V31Upgrade.sol";
import {IL2V31Upgrade} from "contracts/upgrades/IL2V31Upgrade.sol";
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
contract MockV31UpgradeNativeTokenVault {
    bytes32 public immutable BASE_TOKEN_ASSET_ID;
    uint256 public immutable L1_CHAIN_ID;
    bytes32 public immutable L2_TOKEN_PROXY_BYTECODE_HASH;
    address public immutable WETH_TOKEN;

    address public L2_LEGACY_SHARED_BRIDGE;
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
        bytes32 _l2TokenProxyBytecodeHash,
        address _legacySharedBridge,
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

        L2_LEGACY_SHARED_BRIDGE = _legacySharedBridge;
        BASE_TOKEN_ORIGIN_TOKEN = _baseTokenBridgingData.originToken;
        BASE_TOKEN_NAME = _baseTokenMetadata.name;
        BASE_TOKEN_SYMBOL = _baseTokenMetadata.symbol;
        BASE_TOKEN_DECIMALS = _baseTokenMetadata.decimals;
        _originChainId[_baseTokenBridgingData.assetId] = _baseTokenBridgingData.originChainId;
        lastOriginChainId = _baseTokenBridgingData.originChainId;
        updateCalls++;
    }
}

/// @dev Mock AssetTracker that records initL2 and registerBaseTokenDuringUpgrade calls.
contract MockV31UpgradeAssetTracker {
    uint256 public L1_CHAIN_ID;
    bytes32 public BASE_TOKEN_ASSET_ID;

    uint256 public registerCalls;
    bytes32 public lastRegisteredAssetId;
    uint256 public initCalls;

    function initL2(uint256 _l1ChainId, bytes32 _baseTokenAssetId, bool /* _backfillBaseTokenSupply */) external {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert Unauthorized(msg.sender);
        }

        L1_CHAIN_ID = _l1ChainId;
        BASE_TOKEN_ASSET_ID = _baseTokenAssetId;
        initCalls++;
    }

    function registerBaseTokenDuringUpgrade() external {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert Unauthorized(msg.sender);
        }

        registerCalls++;
        lastRegisteredAssetId = BASE_TOKEN_ASSET_ID;
    }
}

/// @dev Mock BaseToken that records initL2 calls and checks ordering vs AssetTracker.
contract MockV31UpgradeBaseToken {
    address private immutable _assetTracker;

    uint256 public initCalls;
    uint256 public lastInitializedL1ChainId;
    bool public sawRegisteredBaseToken;

    constructor(address _assetTrackerAddr) {
        _assetTracker = _assetTrackerAddr;
    }

    function initL2(uint256 _l1ChainId) external {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert Unauthorized(msg.sender);
        }

        initCalls++;
        lastInitializedL1ChainId = _l1ChainId;
        sawRegisteredBaseToken = MockV31UpgradeAssetTracker(_assetTracker).registerCalls() > 0;
    }
}

contract TestL2V31Upgrade is L2V31Upgrade {
    function getAcrossInfo() internal pure override returns (AcrossInfo memory) {
        return
            AcrossInfo({
                proxy: address(0),
                evmImplementation: address(0),
                zkevmRecoveryImplementation: address(0),
                zkevmRecoveryImplConstructorParams: LensSpokePoolConstructorParams({
                    _wrappedNativeTokenAddress: address(0),
                    _circleUSDC: address(0),
                    _zkUSDCBridge: address(0),
                    _cctpTokenMessenger: address(0),
                    _depositQuoteTimeBuffer: 0,
                    _fillDeadlineBuffer: 0
                })
            });
    }
}

contract L2V31UpgradeUnitTest is Test {
    bytes32 internal constant BASE_TOKEN_ASSET_ID = keccak256("base-token");
    uint256 internal constant L1_CHAIN_ID = 9;
    uint256 internal constant ERA_CHAIN_ID = 270;
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

    TestL2V31Upgrade internal testUpgrade;

    function setUp() public {
        // Deploy ComplexUpgrader
        bytes memory complexUpgraderBytecode = vm.getDeployedCode("L2ComplexUpgrader.sol:L2ComplexUpgrader");
        vm.etch(L2_COMPLEX_UPGRADER_ADDR, complexUpgraderBytecode);

        // AcceptAll mock for contracts where we don't verify behavior
        MockAcceptAll acceptAll = new MockAcceptAll();
        address[] memory acceptAllAddresses = new address[](9);
        acceptAllAddresses[0] = L2_DEPLOYER_SYSTEM_CONTRACT_ADDR;
        acceptAllAddresses[1] = L2_MESSAGE_ROOT_ADDR;
        acceptAllAddresses[2] = L2_BRIDGEHUB_ADDR;
        acceptAllAddresses[3] = L2_ASSET_ROUTER_ADDR;
        acceptAllAddresses[4] = L2_CHAIN_ASSET_HANDLER_ADDR;
        acceptAllAddresses[5] = L2_INTEROP_CENTER_ADDR;
        acceptAllAddresses[6] = L2_INTEROP_HANDLER_ADDR;
        acceptAllAddresses[7] = GW_ASSET_TRACKER_ADDR;
        acceptAllAddresses[8] = L2_SYSTEM_CONTRACT_PROXY_ADMIN_ADDR;
        for (uint256 i = 0; i < acceptAllAddresses.length; i++) {
            vm.etch(acceptAllAddresses[i], address(acceptAll).code);
        }

        // Specific mocks for contracts we verify
        _etchCode(
            L2_NATIVE_TOKEN_VAULT_ADDR,
            address(
                new MockV31UpgradeNativeTokenVault(
                    BASE_TOKEN_ASSET_ID,
                    L1_CHAIN_ID,
                    L2_TOKEN_PROXY_BYTECODE_HASH,
                    PREDEPLOYED_WETH
                )
            )
        );
        _etchCode(L2_ASSET_TRACKER_ADDR, address(new MockV31UpgradeAssetTracker()));
        _etchCode(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, address(new MockV31UpgradeBaseToken(L2_ASSET_TRACKER_ADDR)));

        testUpgrade = new TestL2V31Upgrade();
    }

    function test_UpgradeViaComplexUpgrader_RegistersBaseTokenAndInitializesBaseToken() public {
        bytes memory fixedData = abi.encode(_buildFixedForceDeploymentsData());
        bytes memory additionalData = abi.encode(_buildZKChainSpecificData());

        vm.prank(L2_FORCE_DEPLOYER_ADDR);
        L2ComplexUpgrader(L2_COMPLEX_UPGRADER_ADDR).upgrade(
            address(testUpgrade),
            abi.encodeCall(IL2V31Upgrade.upgrade, (false, CTM_DEPLOYER, fixedData, additionalData))
        );

        // Verify AssetTracker: initL2 + registerBaseTokenDuringUpgrade
        MockV31UpgradeAssetTracker assetTracker = MockV31UpgradeAssetTracker(L2_ASSET_TRACKER_ADDR);
        assertEq(assetTracker.initCalls(), 1, "asset tracker should be initialized exactly once");
        assertEq(assetTracker.L1_CHAIN_ID(), L1_CHAIN_ID, "asset tracker L1 chain id mismatch");
        assertEq(assetTracker.registerCalls(), 1, "base token should be registered exactly once");
        assertEq(assetTracker.lastRegisteredAssetId(), BASE_TOKEN_ASSET_ID, "registered asset id mismatch");

        // Verify NTV: updateL2 called with correct data
        MockV31UpgradeNativeTokenVault nativeTokenVault = MockV31UpgradeNativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);
        assertEq(nativeTokenVault.updateCalls(), 1, "native token vault should be updated exactly once");
        assertEq(nativeTokenVault.lastOriginChainId(), BASE_TOKEN_ORIGIN_CHAIN_ID, "origin chain id mismatch");
        assertEq(nativeTokenVault.BASE_TOKEN_ORIGIN_TOKEN(), BASE_TOKEN_ORIGIN_ADDRESS, "origin token mismatch");

        // Verify BaseToken: initL2 called, and it ran AFTER registerBaseTokenDuringUpgrade
        MockV31UpgradeBaseToken baseToken = MockV31UpgradeBaseToken(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        assertEq(baseToken.initCalls(), 1, "base token should be initialized exactly once");
        assertEq(baseToken.lastInitializedL1ChainId(), L1_CHAIN_ID, "base token L1 chain id mismatch");
        assertTrue(baseToken.sawRegisteredBaseToken(), "base token should be initialized after registration");
    }

    function _buildFixedForceDeploymentsData() private pure returns (FixedForceDeploymentsData memory) {
        bytes memory dummyBytecodeInfo = abi.encode(bytes32(0));

        return
            FixedForceDeploymentsData({
                l1ChainId: L1_CHAIN_ID,
                gatewayChainId: GATEWAY_CHAIN_ID,
                eraChainId: ERA_CHAIN_ID,
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
