// SPDX-License-Identifier: MIT

import {ExecutorFacet} from "../../state-transition/chain-deps/facets/Executor.sol";

pragma solidity 0.8.24;

contract TestExecutor is ExecutorFacet {
    /// @dev Since we want to test the blob functionality we want mock the calls to the blobhash opcode.
    function _getBlobVersionedHash(uint256 _index) internal view virtual override returns (bytes32 versionedHash) {
        (bool success, bytes memory data) = s.blobVersionedHashRetriever.staticcall(abi.encode(_index));
        require(success, "vc");
        versionedHash = abi.decode(data, (bytes32));
    }
}
