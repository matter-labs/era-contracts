// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {AtomicFlowPreimage} from "../atomic-interop/IAtomicInterop.sol";

/// @title AttributesDecoder
/// @notice Library for decoding ERC7786 attribute payloads
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

    function decodeAtomicBundle(
        bytes calldata _data
    ) internal pure returns (AtomicFlowPreimage memory flowPreimage, uint256 lowNullifierIndex) {
        return abi.decode(_data[4:], (AtomicFlowPreimage, uint256));
    }

    function decodeBytes32(bytes calldata _data) internal pure returns (bytes32) {
        return abi.decode(_data[4:], (bytes32));
    }
}
