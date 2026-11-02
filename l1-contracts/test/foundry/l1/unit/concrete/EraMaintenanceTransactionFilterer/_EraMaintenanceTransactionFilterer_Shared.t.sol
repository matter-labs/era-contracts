// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {EraMaintenanceTransactionFilterer} from "contracts/transactionFilterer/EraMaintenanceTransactionFilterer.sol";
import {IEraL2LegacyBridge} from "contracts/transactionFilterer/interfaces/IEraL2Legacy.sol";

/// @dev The Bridgehub is mocked: these tests isolate the filterer's own rules. The deposit calldata the
/// real L1 asset router produces is covered by the integration test `EraMaintenanceTransactionFiltererIntegration`.
contract EraMaintenanceTransactionFiltererTest is Test {
    EraMaintenanceTransactionFilterer internal filterer;
    EraMaintenanceTransactionFilterer internal implementation;

    uint256 internal constant CHAIN_ID = 324;
    uint256 internal constant TOKEN_CAP = 1000;
    uint256 internal constant MINT_VALUE = 1 ether;

    address internal owner = makeAddr("owner");
    address internal proxyAdmin = makeAddr("proxyAdmin");
    address internal bridgehub = makeAddr("bridgehub");
    address internal l1AssetRouter = makeAddr("l1AssetRouter");
    address internal user = makeAddr("user");
    address internal l2Receiver = makeAddr("l2Receiver");
    address internal l1Token = makeAddr("l1Token");
    address internal lidoL1Bridge = makeAddr("lidoL1Bridge");
    address internal lidoL1Token = makeAddr("lidoL1Token");

    bytes32 internal baseTokenAssetId = keccak256("baseTokenAssetId");
    bytes32 internal tokenAssetId;
    bytes32 internal lidoAssetId;

    function setUp() public virtual {
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.assetRouter, ()), abi.encode(l1AssetRouter));
        vm.mockCall(
            bridgehub,
            abi.encodeCall(IBridgehubBase.baseTokenAssetId, (CHAIN_ID)),
            abi.encode(baseTokenAssetId)
        );

        tokenAssetId = DataEncoding.encodeNTVAssetId(block.chainid, l1Token);
        lidoAssetId = DataEncoding.encodeNTVAssetId(block.chainid, lidoL1Token);

        implementation = new EraMaintenanceTransactionFilterer(IBridgehubBase(bridgehub));
        filterer = EraMaintenanceTransactionFilterer(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation),
                    proxyAdmin,
                    abi.encodeCall(EraMaintenanceTransactionFilterer.initialize, (owner, CHAIN_ID))
                )
            )
        );
    }

    function _newDepositCalldata(
        address _depositor,
        bytes32 _assetId,
        uint256 _amount
    ) internal view returns (bytes memory) {
        bytes memory transferData = DataEncoding.encodeBridgeMintData({
            _originalCaller: _depositor,
            _remoteReceiver: l2Receiver,
            _originToken: l1Token,
            _amount: _amount,
            _erc20Metadata: hex""
        });
        return abi.encodeCall(AssetRouterBase.finalizeDeposit, (block.chainid, _assetId, transferData));
    }

    function _legacyDepositCalldata(
        address _depositor,
        address _l1Token,
        uint256 _amount
    ) internal view returns (bytes memory) {
        return abi.encodeCall(IEraL2LegacyBridge.finalizeDeposit, (_depositor, l2Receiver, _l1Token, _amount, hex""));
    }

    function _setCap(bytes32 _assetId, uint256 _cap) internal {
        bytes32[] memory assetIds = new bytes32[](1);
        assetIds[0] = _assetId;
        uint256[] memory caps = new uint256[](1);
        caps[0] = _cap;
        vm.prank(owner);
        filterer.setDepositCaps(assetIds, caps);
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
