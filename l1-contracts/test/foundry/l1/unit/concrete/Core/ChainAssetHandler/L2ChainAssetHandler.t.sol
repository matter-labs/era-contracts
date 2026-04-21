// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {L2ChainAssetHandler} from "contracts/core/chain-asset-handler/L2ChainAssetHandler.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IMigrator} from "contracts/state-transition/chain-interfaces/IMigrator.sol";
import {SERVICE_TRANSACTION_SENDER} from "contracts/common/Config.sol";
import {ChainIdNotRegistered, Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {
    L2_BRIDGEHUB_ADDR,
    L2_CHAIN_ASSET_HANDLER_ADDR,
    L2_COMPLEX_UPGRADER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

contract MockMigrator {
    function pauseDepositsOnGateway(uint256) external {}
}

contract L2ChainAssetHandlerTest is Test {
    uint256 internal constant L1_CHAIN_ID = 1;
    uint256 internal constant CHAIN_ID = 2;

    address internal mockBridgehub;
    address internal mockZKChain;

    function setUp() public {
        mockBridgehub = makeAddr("mockBridgehub");
        mockZKChain = makeAddr("mockZKChain");

        vm.etch(L2_BRIDGEHUB_ADDR, address(mockBridgehub).code);
        vm.etch(L2_CHAIN_ASSET_HANDLER_ADDR, type(L2ChainAssetHandler).runtimeCode);

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        L2ChainAssetHandler(L2_CHAIN_ASSET_HANDLER_ADDR).initL2(L1_CHAIN_ID, address(this));
    }

    function test_RequestPauseDepositsForChainOnGateway_Unauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        L2ChainAssetHandler(L2_CHAIN_ASSET_HANDLER_ADDR).requestPauseDepositsForChainOnGateway(CHAIN_ID);
    }

    function test_RequestPauseDepositsForChainOnGateway_ChainNotRegistered() public {
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, CHAIN_ID),
            abi.encode(address(0))
        );

        vm.prank(SERVICE_TRANSACTION_SENDER);
        vm.expectRevert(abi.encodeWithSelector(ChainIdNotRegistered.selector, CHAIN_ID));
        L2ChainAssetHandler(L2_CHAIN_ASSET_HANDLER_ADDR).requestPauseDepositsForChainOnGateway(CHAIN_ID);
    }

    function test_RequestPauseDepositsForChainOnGateway_Success() public {
        vm.etch(mockZKChain, address(new MockMigrator()).code);
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, CHAIN_ID),
            abi.encode(mockZKChain)
        );

        vm.expectCall(
            mockZKChain,
            abi.encodeWithSelector(IMigrator.pauseDepositsOnGateway.selector, block.timestamp)
        );

        vm.prank(SERVICE_TRANSACTION_SENDER);
        L2ChainAssetHandler(L2_CHAIN_ASSET_HANDLER_ADDR).requestPauseDepositsForChainOnGateway(CHAIN_ID);
    }
}
