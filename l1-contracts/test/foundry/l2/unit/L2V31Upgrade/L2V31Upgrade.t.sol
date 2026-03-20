// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {
    L2_ASSET_TRACKER_ADDR,
    L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_FORCE_DEPLOYER_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {L2ComplexUpgrader} from "contracts/l2-upgrades/L2ComplexUpgrader.sol";
import {AcrossInfo, LensSpokePoolConstructorParams} from "contracts/l2-upgrades/V31AcrossRecovery.sol";
import {L2V31Upgrade} from "contracts/l2-upgrades/L2V31Upgrade.sol";
import {IL2V31Upgrade} from "contracts/upgrades/IL2V31Upgrade.sol";
import {AddressMismatch, ChainIdMismatch, Unauthorized} from "contracts/common/L1ContractErrors.sol";

contract MockV31UpgradeNativeTokenVault {
    bytes32 public immutable BASE_TOKEN_ASSET_ID;
    uint256 private immutable _baseTokenOriginChainId;
    address private immutable _baseTokenOriginAddress;

    constructor(bytes32 _assetId, uint256 _originChainId, address _originAddress) {
        BASE_TOKEN_ASSET_ID = _assetId;
        _baseTokenOriginChainId = _originChainId;
        _baseTokenOriginAddress = _originAddress;
    }

    function originChainId(bytes32 _assetId) external view returns (uint256) {
        if (_assetId == BASE_TOKEN_ASSET_ID) {
            return _baseTokenOriginChainId;
        }
        return 0;
    }

    function originToken(bytes32 _assetId) external view returns (address) {
        if (_assetId == BASE_TOKEN_ASSET_ID) {
            return _baseTokenOriginAddress;
        }
        return address(0);
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

        _etchCode(
            L2_NATIVE_TOKEN_VAULT_ADDR,
            address(
                new MockV31UpgradeNativeTokenVault(
                    BASE_TOKEN_ASSET_ID,
                    BASE_TOKEN_ORIGIN_CHAIN_ID,
                    BASE_TOKEN_ORIGIN_ADDRESS
                )
            )
        );
        _etchCode(L2_ASSET_TRACKER_ADDR, address(new MockV31UpgradeAssetTracker(BASE_TOKEN_ASSET_ID, L1_CHAIN_ID)));
        _etchCode(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, address(new MockV31UpgradeBaseToken(L2_ASSET_TRACKER_ADDR)));

        testUpgrade = new TestL2V31Upgrade();
    }

    function test_UpgradeViaComplexUpgrader_RegistersBaseTokenAndInitializesBaseToken() public {
        vm.prank(L2_FORCE_DEPLOYER_ADDR);
        L2ComplexUpgrader(L2_COMPLEX_UPGRADER_ADDR).upgrade(
            address(testUpgrade),
            abi.encodeCall(IL2V31Upgrade.upgrade, (BASE_TOKEN_ORIGIN_CHAIN_ID, BASE_TOKEN_ORIGIN_ADDRESS))
        );

        MockV31UpgradeAssetTracker assetTracker = MockV31UpgradeAssetTracker(L2_ASSET_TRACKER_ADDR);
        assertEq(assetTracker.registerCalls(), 1, "base token should be registered exactly once");
        assertEq(assetTracker.lastRegisteredAssetId(), BASE_TOKEN_ASSET_ID, "registered asset id mismatch");

        MockV31UpgradeBaseToken baseToken = MockV31UpgradeBaseToken(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR);
        assertEq(baseToken.initCalls(), 1, "base token should be initialized exactly once");
        assertEq(baseToken.lastInitializedL1ChainId(), L1_CHAIN_ID, "base token L1 chain id mismatch");
        assertTrue(baseToken.sawRegisteredBaseToken(), "base token should be initialized after registration");
    }

    function test_RevertWhen_BaseTokenOriginChainIdDoesNotMatchNativeTokenVault() public {
        vm.prank(L2_FORCE_DEPLOYER_ADDR);
        vm.expectRevert(ChainIdMismatch.selector);
        L2ComplexUpgrader(L2_COMPLEX_UPGRADER_ADDR).upgrade(
            address(testUpgrade),
            abi.encodeCall(IL2V31Upgrade.upgrade, (BASE_TOKEN_ORIGIN_CHAIN_ID + 1, BASE_TOKEN_ORIGIN_ADDRESS))
        );
    }

    function test_RevertWhen_BaseTokenOriginAddressDoesNotMatchNativeTokenVault() public {
        vm.prank(L2_FORCE_DEPLOYER_ADDR);
        vm.expectRevert(abi.encodeWithSelector(AddressMismatch.selector, address(0x5678), BASE_TOKEN_ORIGIN_ADDRESS));
        L2ComplexUpgrader(L2_COMPLEX_UPGRADER_ADDR).upgrade(
            address(testUpgrade),
            abi.encodeCall(IL2V31Upgrade.upgrade, (BASE_TOKEN_ORIGIN_CHAIN_ID, address(0x5678)))
        );
    }

    function _etchCode(address _target, address _source) private {
        vm.etch(_target, _source.code);
    }
}
