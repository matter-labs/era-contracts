// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Base tokens the ERC20 metadata probe has to survive, shared by every test of the
///         per-chain force-deployments composition. Real contracts rather than mocked calls: the
///         probe's whole point is how a token's RETURNDATA behaves.

/// @dev No metadata methods at all: every probe reverts on the missing selector.
contract NoMetadataToken {}

/// @dev Maker-style: `name()` and `symbol()` answer with a raw `bytes32` rather than a `string`.
contract Bytes32MetadataToken {
    bytes32 private immutable _NAME;
    bytes32 private immutable _SYMBOL;
    uint8 private immutable _DECIMALS;

    constructor(bytes32 _name, bytes32 _symbol, uint8 _decimals) {
        _NAME = _name;
        _SYMBOL = _symbol;
        _DECIMALS = _decimals;
    }

    function name() external view returns (bytes32) {
        return _NAME;
    }

    function symbol() external view returns (bytes32) {
        return _SYMBOL;
    }

    function decimals() external view returns (uint8) {
        return _DECIMALS;
    }
}
