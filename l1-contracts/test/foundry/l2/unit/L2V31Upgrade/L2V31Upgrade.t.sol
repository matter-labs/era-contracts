// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {
    L2_ASSET_TRACKER_ADDR,
    L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
    L2_BRIDGEHUB_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_FORCE_DEPLOYER_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {L2ComplexUpgrader} from "contracts/l2-upgrades/L2ComplexUpgrader.sol";
import {AcrossInfo, LensSpokePoolConstructorParams} from "contracts/l2-upgrades/V31AcrossRecovery.sol";
import {L2V31Upgrade} from "contracts/l2-upgrades/L2V31Upgrade.sol";
import {IL2V31Upgrade} from "contracts/upgrades/IL2V31Upgrade.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {TokenBridgingData, TokenMetadata} from "contracts/common/Messaging.sol";

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

    constructor(bytes32 _assetId, uint256 _l1ChainId) {
        BASE_TOKEN_ASSET_ID = _assetId;
        L1_CHAIN_ID = _l1ChainId;
        L2_TOKEN_PROXY_BYTECODE_HASH = keccak256("proxy");
        WETH_TOKEN = address(0xdead);
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

contract MockV31UpgradeAssetTracker {
    bytes32 public immutable BASE_TOKEN_ASSET_ID;
    uint256 public immutable L1_CHAIN_ID;

    uint256 public registerCalls;
    bytes32 public lastRegisteredAssetId;

    constructor(bytes32 _baseTokenAssetId, uint256 _l1ChainId) {
        BASE_TOKEN_ASSET_ID = _baseTokenAssetId;
        L1_CHAIN_ID = _l1ChainId;
    }

    function registerBaseTokenDuringUpgrade() external {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert Unauthorized(msg.sender);
        }

        registerCalls++;
        lastRegisteredAssetId = BASE_TOKEN_ASSET_ID;
    }
}

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

contract MockV31UpgradeBridgehub {
    uint256 public immutable L1_CHAIN_ID;

    constructor(uint256 _l1ChainId) {
        L1_CHAIN_ID = _l1ChainId;
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
    uint256 internal constant BASE_TOKEN_ORIGIN_CHAIN_ID = 1;
    address internal constant BASE_TOKEN_ORIGIN_ADDRESS = address(0x1234);

    TestL2V31Upgrade internal testUpgrade;

    function setUp() public {
        bytes memory complexUpgraderBytecode = vm.getDeployedCode("L2ComplexUpgrader.sol:L2ComplexUpgrader");
        vm.etch(L2_COMPLEX_UPGRADER_ADDR, complexUpgraderBytecode);

        _etchCode(L2_BRIDGEHUB_ADDR, address(new MockV31UpgradeBridgehub(L1_CHAIN_ID)));
        _etchCode(
            L2_NATIVE_TOKEN_VAULT_ADDR,
            address(new MockV31UpgradeNativeTokenVault(BASE_TOKEN_ASSET_ID, L1_CHAIN_ID))
        );
        _etchCode(L2_ASSET_TRACKER_ADDR, address(new MockV31UpgradeAssetTracker(BASE_TOKEN_ASSET_ID, L1_CHAIN_ID)));
        _etchCode(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, address(new MockV31UpgradeBaseToken(L2_ASSET_TRACKER_ADDR)));

        testUpgrade = new TestL2V31Upgrade();
    }

    function test_UpgradeViaComplexUpgrader_RegistersBaseTokenAndInitializesBaseToken() public {
        vm.prank(L2_FORCE_DEPLOYER_ADDR);
        L2ComplexUpgrader(L2_COMPLEX_UPGRADER_ADDR).upgrade(
            address(testUpgrade),
            abi.encodeCall(
                IL2V31Upgrade.upgrade,
                (false, address(0), "", "")
            )
        );

        MockV31UpgradeAssetTracker assetTracker = MockV31UpgradeAssetTracker(L2_ASSET_TRACKER_ADDR);
        assertEq(assetTracker.registerCalls(), 1, "base token should be registered exactly once");
        assertEq(assetTracker.lastRegisteredAssetId(), BASE_TOKEN_ASSET_ID, "registered asset id mismatch");

        MockV31UpgradeNativeTokenVault nativeTokenVault = MockV31UpgradeNativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);
        assertEq(nativeTokenVault.updateCalls(), 1, "native token vault should be updated exactly once");
        assertEq(nativeTokenVault.lastOriginChainId(), BASE_TOKEN_ORIGIN_CHAIN_ID, "origin chain id mismatch");
        assertEq(nativeTokenVault.BASE_TOKEN_ORIGIN_TOKEN(), BASE_TOKEN_ORIGIN_ADDRESS, "origin token mismatch");

        MockV31UpgradeBaseToken baseToken = MockV31UpgradeBaseToken(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        assertEq(baseToken.initCalls(), 1, "base token should be initialized exactly once");
        assertEq(baseToken.lastInitializedL1ChainId(), L1_CHAIN_ID, "base token L1 chain id mismatch");
        assertTrue(baseToken.sawRegisteredBaseToken(), "base token should be initialized after registration");
    }

    function _etchCode(address _target, address _source) private {
        vm.etch(_target, _source.code);
    }
}
