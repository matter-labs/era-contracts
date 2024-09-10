// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// solhint-disable gas-custom-errors

import {IERC20Metadata} from "@openzeppelin/contracts-v4/token/ERC20/extensions/IERC20Metadata.sol";
import {ETH_TOKEN_ADDRESS} from "../common/Config.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Helper library for working with L2 contracts on L1.
 */
library BridgeHelper {
    /// @dev Receives and parses (name, symbol, decimals) from the token contract
    function getERC20Getters(
        address _token,
        bool _legacy,
        uint256 _originChainId
    ) internal view returns (bytes memory) {
        if (_token == ETH_TOKEN_ADDRESS) {
            bytes memory name = abi.encode("Ether");
            bytes memory symbol = abi.encode("ETH");
            bytes memory decimals = abi.encode(uint8(18));
            return abi.encode(name, symbol, decimals); // when depositing eth to a non-eth based chain it is an ERC20
        }
        /// note this also works on the L2 for the base token.
        (, bytes memory data1) = _token.staticcall(abi.encodeCall(IERC20Metadata.name, ()));
        (, bytes memory data2) = _token.staticcall(abi.encodeCall(IERC20Metadata.symbol, ()));
        (, bytes memory data3) = _token.staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        return
            DataEncoding.encodeTokenData({
                _legacy: _legacy,
                _originChainId: _originChainId,
                _name: data1,
                _symbol: data2,
                _decimals: data3
            });
    }
}
