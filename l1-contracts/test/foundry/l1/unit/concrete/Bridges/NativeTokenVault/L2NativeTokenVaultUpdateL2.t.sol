// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BeaconProxy} from "@openzeppelin/contracts-v4/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";

import {IL2NativeTokenVault} from "contracts/bridge/ntv/IL2NativeTokenVault.sol";
import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";
import {TokenBridgingData, TokenMetadata} from "contracts/common/Messaging.sol";
import {L2_COMPLEX_UPGRADER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {AssetIdMismatch} from "contracts/common/L1ContractErrors.sol";

/// @notice Regression coverage for L2NativeTokenVault upgrade initialization and compatibility invariants.
contract L2NativeTokenVaultUpdateL2Test is Test {
    L2NativeTokenVault internal ntv;

    address internal aliasedOwner = makeAddr("aliasedOwner");
    address internal weth = makeAddr("weth");
    address internal baseOriginToken = makeAddr("baseOriginToken");
    uint256 internal constant L1_CHAIN_ID = 1;
    bytes32 internal constant ASSET_A = keccak256("base token A");
    bytes32 internal constant ASSET_B = keccak256("base token B");

    function setUp() public {
        ntv = new L2NativeTokenVault();
    }

    function _updateL2As(address _caller, bytes32 _assetId) internal {
        vm.prank(_caller);
        ntv.updateL2({
            _l1ChainId: L1_CHAIN_ID,
            _aliasedOwner: aliasedOwner,
            _wethToken: weth,
            _baseTokenBridgingData: TokenBridgingData({
                assetId: _assetId,
                originChainId: L1_CHAIN_ID,
                originToken: baseOriginToken
            }),
            _baseTokenMetadata: TokenMetadata({name: "Base", symbol: "BASE", decimals: 18})
        });
    }

    function test_updateL2_setsBaseTokenAssetIdOnFirstCall() external {
        _updateL2As(L2_COMPLEX_UPGRADER_ADDR, ASSET_A);
        assertEq(ntv.BASE_TOKEN_ASSET_ID(), ASSET_A);
    }

    function test_updateL2_allowsReSettingTheSameBaseTokenAssetId() external {
        _updateL2As(L2_COMPLEX_UPGRADER_ADDR, ASSET_A);
        _updateL2As(L2_COMPLEX_UPGRADER_ADDR, ASSET_A);
        assertEq(ntv.BASE_TOKEN_ASSET_ID(), ASSET_A);
    }

    function test_updateL2_revertsWhenChangingBaseTokenAssetId() external {
        _updateL2As(L2_COMPLEX_UPGRADER_ADDR, ASSET_A);

        vm.expectRevert(abi.encodeWithSelector(AssetIdMismatch.selector, ASSET_A, ASSET_B));
        _updateL2As(L2_COMPLEX_UPGRADER_ADDR, ASSET_B);
    }

    function test_updateL2_preservesDeprecatedProxyHashSlotAndNeighbors() external {
        _updateL2As(L2_COMPLEX_UPGRADER_ADDR, ASSET_A);

        assertEq(vm.load(address(ntv), bytes32(uint256(254))), bytes32(0), "legacy bridge tombstone moved");
        assertEq(vm.load(address(ntv), bytes32(uint256(255))), bytes32(0), "proxy hash tombstone written");
        assertEq(
            vm.load(address(ntv), bytes32(uint256(256))),
            bytes32(uint256(uint160(baseOriginToken))),
            "base token origin slot moved"
        );
        assertEq(vm.load(address(ntv), bytes32(uint256(259))), bytes32(uint256(18)), "decimals slot moved");
    }

    function test_proxyBytecodeHashGetterAndBeaconEventUseActualRuntimeHash() external {
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(ntv));
        BeaconProxy proxy = new BeaconProxy(address(beacon), "");
        bytes32 expectedProxyBytecodeHash = address(proxy).codehash;

        assertEq(IL2NativeTokenVault.L2_TOKEN_PROXY_BYTECODE_HASH.selector, bytes4(0x2149ed74));
        assertEq(ntv.L2_TOKEN_PROXY_BYTECODE_HASH(), expectedProxyBytecodeHash);

        vm.expectEmit(true, true, false, false, address(ntv));
        emit IL2NativeTokenVault.L2TokenBeaconUpdated(address(beacon), expectedProxyBytecodeHash);

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        ntv.initL2({
            _l1ChainId: L1_CHAIN_ID,
            _aliasedOwner: address(0),
            _bridgedTokenBeacon: address(beacon),
            _wethToken: weth,
            _baseTokenBridgingData: TokenBridgingData({
                assetId: ASSET_A,
                originChainId: L1_CHAIN_ID,
                originToken: baseOriginToken
            }),
            _baseTokenMetadata: TokenMetadata({name: "Base", symbol: "BASE", decimals: 18})
        });
    }
}
