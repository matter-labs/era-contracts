// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";
import {BadTransferDataLength} from "contracts/common/L1ContractErrors.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

contract TestAssetRouterBase is AssetRouterBase {
    // constructor() AssetRouterBase(1, 1, IBridgehubBase(address(1))) {}

    function setAssetHandlerAddressThisChain(bytes32, address) external override {}

    function bridgehubDepositBaseToken(uint256, bytes32, address, uint256) external payable override {}

    function finalizeDeposit(uint256, bytes32, bytes calldata) public payable override {}

    // Use a specific name that won't trigger fuzz testing
    function callGetTransferData(bytes calldata data) external returns (bytes32, bytes memory) {
        return _getTransferData(data);
    }

    function BRIDGE_HUB() external view returns (IBridgehubBase) {
        return IBridgehubBase(address(1));
    }

    function L1_CHAIN_ID() external view returns (uint256) {
        return 1;
    }

    function _bridgehub() internal view override returns (IBridgehubBase) {
        return IBridgehubBase(address(1));
    }

    function _interopHandler() internal view override returns (address) {
        return address(1);
    }

    function _isValidInteropSender(uint256, address) internal view override returns (bool) {
        return true;
    }

    function _l1ChainId() internal view returns (uint256) {
        return 1;
    }

    function _eraChainId() internal view returns (uint256) {
        return 1;
    }
}

contract AssetRouterBase_GetTransferDataErrors_Test is Test {
    TestAssetRouterBase router;

    function setUp() public {
        router = new TestAssetRouterBase();
    }

    function test_BadTransferDataLength_WhenDataTooShort() public {
        bytes memory shortData = hex"01"; // NEW_ENCODING_VERSION but only 1 byte
        vm.expectRevert(BadTransferDataLength.selector);
        router.callGetTransferData(shortData);
    }
}
