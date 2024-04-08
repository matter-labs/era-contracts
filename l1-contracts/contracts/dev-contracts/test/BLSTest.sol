// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "../../zksync/libraries/BLS.sol";

contract BLSTest {
    function verifyAggregation(
        uint256[2][] calldata pk1s,
        uint256[4] calldata aggregated_pk2s,
        uint256[2] calldata aggregated_sig,
        bytes calldata msg,
        uint256 nonce
    ) external view returns (bool) {
        return BLS.verifyAggregation(pk1s, aggregated_pk2s, aggregated_sig, msg, nonce);
    }

    function hashToPoint(bytes calldata msg, uint256 nonce) external view returns (uint256[2] memory p) {
        return BLS.hashToPoint(msg, nonce);
    }

    function sqrt(uint256 xx) external view returns (uint256 x, bool hasRoot) {
        return BLS.sqrt(xx);
    }
}
