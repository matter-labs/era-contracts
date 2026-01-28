// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";
import {BadTransferDataLength, UnsupportedEncodingVersion} from "contracts/common/L1ContractErrors.sol";
import {NEW_ENCODING_VERSION} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

contract TestAssetRouterBase is AssetRouterBase {
    // constructor() AssetRouterBase(1, 1, IBridgehubBase(address(1))) {}

    function setAssetHandlerAddressThisChain(bytes32, address) external override {}

    function bridgehubDepositBaseToken(uint256, bytes32, address, uint256) external payable override {}

    function finalizeDeposit(uint256, bytes32, bytes calldata) public payable override {}

    function _ensureTokenRegisteredWithNTV(address) internal pure override returns (bytes32) {
        return keccak256("test");
    }

    // Use a specific name that won't trigger fuzz testing
    function callGetTransferData(bytes1 encodingVersion, bytes calldata data) external returns (bytes32, bytes memory) {
        return _getTransferData(encodingVersion, address(0), data);
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
        router.callGetTransferData(NEW_ENCODING_VERSION, shortData);
    }

    function test_UnsupportedEncodingVersion_WhenNotNew() public {
        bytes memory data = hex"02"; // invalid encoding version
        vm.expectRevert(UnsupportedEncodingVersion.selector);
        router.callGetTransferData(bytes1(0x02), data);
    }
}
