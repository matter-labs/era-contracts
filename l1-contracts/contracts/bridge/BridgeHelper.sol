// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts-v4/token/ERC20/extensions/IERC20Metadata.sol";
import {ETH_TOKEN_ADDRESS} from "../common/Config.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Helper library for working with native tokens on both L1 and L2.
 */
library BridgeHelper {
    /// @dev Receives and parses (name, symbol, decimals) from the token contract
    function getERC20Getters(address _token, uint256 _originChainId) internal view returns (bytes memory) {
        bytes memory name;
        bytes memory symbol;
        bytes memory decimals;
        if (_token == ETH_TOKEN_ADDRESS) {
            // when depositing eth to a non-eth based chain it is an ERC20
            name = abi.encode("Ether");
            symbol = abi.encode("ETH");
            decimals = abi.encode(uint8(18));
        } else {
            bool success;
            /// note this also works on the L2 for the base token.
            (success, name) = _token.staticcall(abi.encodeCall(IERC20Metadata.name, ()));
            if (!success) {
                // We ignore the revert data
                name = hex"";
            }
            (success, symbol) = _token.staticcall(abi.encodeCall(IERC20Metadata.symbol, ()));
            if (!success) {
                // We ignore the revert data
                symbol = hex"";
            }
            (success, decimals) = _token.staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
            if (!success) {
                // We ignore the revert data
                decimals = hex"";
            }
        }
        return
            DataEncoding.encodeTokenData({_chainId: _originChainId, _name: name, _symbol: symbol, _decimals: decimals});
    }
}
