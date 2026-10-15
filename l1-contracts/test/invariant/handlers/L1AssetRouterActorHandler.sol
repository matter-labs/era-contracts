// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {L2_ASSET_ROUTER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";

import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";

import {
    AMOUNT_UPPER_BOUND,
    L1_TOKEN_ADDRESS,
    TOKEN_DEFAULT_DECIMALS,
    TOKEN_DEFAULT_NAME,
    TOKEN_DEFAULT_SYMBOL
} from "../common/Constants.sol";
import {UserActorHandler} from "./UserActorHandler.sol";

contract L1AssetRouterActorHandler is Test {
    UserActorHandler[] public receivers;

    uint256 public ghost_totalDeposits;

    error ReceiversArrayIsEmpty();

    constructor(UserActorHandler[] memory _receivers) {
        if (_receivers.length == 0) {
            revert ReceiversArrayIsEmpty();
        }
        receivers = _receivers;
    }

    function finalizeDeposit(uint256 _amount, address _sender, uint256 _receiverIndex) public {
        uint256 l1ChainId = L2AssetRouter(L2_ASSET_ROUTER_ADDR).L1_CHAIN_ID();
        bytes32 assetId = DataEncoding.encodeNTVAssetId(l1ChainId, L1_TOKEN_ADDRESS);
        uint256 receiverIndex = bound(_receiverIndex, 0, receivers.length - 1);
        uint256 amount = bound(_amount, 0, AMOUNT_UPPER_BOUND);
        bytes memory data = DataEncoding.encodeBridgeMintData({
            _originalCaller: _sender,
            _remoteReceiver: address(receivers[receiverIndex]),
            _originToken: L1_TOKEN_ADDRESS,
            _amount: amount,
            _erc20Metadata: DataEncoding.encodeTokenData(
                l1ChainId,
                abi.encode(TOKEN_DEFAULT_NAME),
                abi.encode(TOKEN_DEFAULT_SYMBOL),
                abi.encode(TOKEN_DEFAULT_DECIMALS)
            )
        });

        address l1AssetRouter = address(L2AssetRouter(L2_ASSET_ROUTER_ADDR).L1_ASSET_ROUTER());
        vm.prank(AddressAliasHelper.applyL1ToL2Alias(l1AssetRouter));
        L2AssetRouter(L2_ASSET_ROUTER_ADDR).finalizeDeposit(l1ChainId, assetId, data);

        ghost_totalDeposits += amount;
    }
}
