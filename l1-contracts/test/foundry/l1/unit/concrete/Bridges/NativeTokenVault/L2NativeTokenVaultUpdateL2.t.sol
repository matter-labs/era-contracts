// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L2NativeTokenVault} from "contracts/bridge/ntv/L2NativeTokenVault.sol";
import {TokenBridgingData, TokenMetadata} from "contracts/common/Messaging.sol";
import {L2_COMPLEX_UPGRADER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {AssetIdMismatch} from "contracts/common/L1ContractErrors.sol";

/// @notice Regression tests for the `BASE_TOKEN_ASSET_ID` freeze: `L2NativeTokenVault.updateL2` must freeze it once set — the
/// same "set-once" pattern already applied to `WETH_TOKEN` and `L1_CHAIN_ID`. A base-token change would strand
/// every in-flight bundle whose snapshotted `destinationBaseTokenAssetId` no longer matches the vault's value.
contract L2NativeTokenVaultUpdateL2Test is Test {
    L2NativeTokenVault internal ntv;

    address internal aliasedOwner = makeAddr("aliasedOwner");
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
            _l2TokenProxyBytecodeHash: bytes32(uint256(1)),
            _wethToken: makeAddr("weth"),
            _baseTokenBridgingData: TokenBridgingData({
                assetId: _assetId,
                originChainId: L1_CHAIN_ID,
                originToken: makeAddr("baseOriginToken")
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
}
