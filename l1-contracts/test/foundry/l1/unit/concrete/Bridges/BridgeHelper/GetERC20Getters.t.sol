// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {BridgeHelperTest} from "contracts/dev-contracts/test/BridgeHelperTest.sol";
import {RevertFallback} from "contracts/dev-contracts/RevertFallback.sol";

contract GetERC20GettersTest is Test {
    BridgeHelperTest helper;
    RevertFallback bad;

    function setUp() public {
        helper = new BridgeHelperTest();
        bad = new RevertFallback();
    }

    function _decode(
        bytes memory data
    )
        internal
        pure
        returns (uint256 chainId, bytes memory nameBytes, bytes memory symbolBytes, bytes memory decimalsBytes)
    {
        // Skip the first byte (encoding version)
        bytes memory tail = new bytes(data.length - 1);
        for (uint256 i = 1; i < data.length; i++) {
            tail[i - 1] = data[i];
        }
        (chainId, nameBytes, symbolBytes, decimalsBytes) = abi.decode(tail, (uint256, bytes, bytes, bytes));
    }

    function test_ETH_ReturnsEtherEth18() public view {
        bytes memory data = helper.callGetters(address(1), 1337);
        (uint256 chainId, bytes memory nameBytes, bytes memory symbolBytes, bytes memory decimalsBytes) = _decode(data);

        assertEq(chainId, 1337, "chainId");
        assertEq(keccak256(nameBytes), keccak256(abi.encode("Ether")), "name");
        assertEq(keccak256(symbolBytes), keccak256(abi.encode("ETH")), "symbol");
        assertEq(keccak256(decimalsBytes), keccak256(abi.encode(uint8(18))), "decimals");
    }

    function test_FailedStaticcalls_ReturnsEmptyBytes() public view {
        bytes memory data = helper.callGetters(address(bad), 1);
        (uint256 chainId, bytes memory nameBytes, bytes memory symbolBytes, bytes memory decimalsBytes) = _decode(data);

        assertEq(chainId, 1, "chainId");
        assertEq(nameBytes.length, 0, "name empty");
        assertEq(symbolBytes.length, 0, "symbol empty");
        assertEq(decimalsBytes.length, 0, "decimals empty");
    }
}
