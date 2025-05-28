// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

/// @title IERC7786AttributesDecoder
/// @notice Interface for the ERC7786 attributes decoder
/// https://github.com/ethereum/ERCs/blob/023a7d657666308568d3d1391c578d5972636093/ERCS/erc-7786.md
library AttributesDecoder {
    function decodeIndirectCall(bytes calldata _data) internal pure returns (bytes4, uint256) {
        return (bytes4(_data[0:4]), uint256(bytes32(_data[4:36])));
    }
}
