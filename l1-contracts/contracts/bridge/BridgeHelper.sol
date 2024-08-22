// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// solhint-disable gas-custom-errors

import {IERC20Metadata} from "@openzeppelin/contracts-v4/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Helper library for working with L2 contracts on L1.
 */
library BridgeHelper {
    /// @dev Receives and parses (name, symbol, decimals) from the token contract
    function getERC20Getters(address _token, address _ethTokenAddress) internal view returns (bytes memory) {
        if (_token == _ethTokenAddress) {
            bytes memory name = abi.encode("Ether");
            bytes memory symbol = abi.encode("ETH");
            bytes memory decimals = abi.encode(uint8(18));
            return abi.encode(name, symbol, decimals); // when depositing eth to a non-eth based chain it is an ERC20
        }

        (, bytes memory data1) = _token.staticcall(abi.encodeCall(IERC20Metadata.name, ()));
        (, bytes memory data2) = _token.staticcall(abi.encodeCall(IERC20Metadata.symbol, ()));
        (, bytes memory data3) = _token.staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        return abi.encode(data1, data2, data3);
    }
}
