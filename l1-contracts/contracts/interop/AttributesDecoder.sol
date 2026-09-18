// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

/// @title IERC7786AttributesDecoder
/// @notice Interface for the ERC7786 attributes decoder
/// https://github.com/ethereum/ERCs/blob/023a7d657666308568d3d1391c578d5972636093/ERCS/erc-7786.md
library AttributesDecoder {
    function decodeUint256(bytes calldata _data) internal pure returns (uint256) {
        return abi.decode(_data[4:], (uint256));
    }

    function decodeInteroperableAddress(bytes calldata _data) internal pure returns (bytes memory) {
        return abi.decode(_data[4:], (bytes));
    }

    function decodeBool(bytes calldata _data) internal pure returns (bool) {
        return abi.decode(_data[4:], (bool));
    }
}
