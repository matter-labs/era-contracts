// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";
import {BadTransferDataLength} from "contracts/common/L1ContractErrors.sol";
import {NEW_ENCODING_VERSION} from "contracts/bridge/asset-router/IAssetRouterBase.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

contract TestAssetRouterBase is AssetRouterBase {
    // constructor() AssetRouterBase(1, 1, IBridgehubBase(address(1))) {}

    function setAssetHandlerAddressThisChain(bytes32, address) external override {}

    function bridgehubDepositBaseToken(uint256, bytes32, address, uint256) external payable override {}

    function finalizeDeposit(uint256, bytes32, bytes calldata) public payable override {}

    // Use a specific name that won't trigger fuzz testing
    function callGetTransferData(bytes1 encodingVersion, bytes calldata data) external returns (bytes32, bytes memory) {
        return _getTransferData(encodingVersion, data);
    }

    function BRIDGE_HUB() external pure returns (IBridgehubBase) {
        return IBridgehubBase(address(1));
    }

    function L1_CHAIN_ID() external pure returns (uint256) {
        return 1;
    }

    function _getBridgehub() internal pure override returns (IBridgehubBase) {
        return IBridgehubBase(address(1));
    }

    function _getInteropHandler() internal pure override returns (address) {
        return address(1);
    }

    function _isValidInteropSender(uint256, address) internal pure override returns (bool) {
        return true;
    }

    function _getL1ChainId() internal pure returns (uint256) {
        return 1;
    }

    function _eraChainId() internal pure returns (uint256) {
        return 1;
    }
}

contract AssetRouterBaseGetTransferDataErrorsTest is Test {
    TestAssetRouterBase internal router;

    function setUp() public {
        router = new TestAssetRouterBase();
    }

    function test_BadTransferDataLength_WhenDataTooShort() public {
        bytes memory shortData = hex"01"; // NEW_ENCODING_VERSION but only 1 byte
        vm.expectRevert(BadTransferDataLength.selector);
        router.callGetTransferData(NEW_ENCODING_VERSION, shortData);
    }
}
