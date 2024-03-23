// SPDX-License-Identifier: MIT

import {ExecutorFacet} from "solpp/state-transition/chain-deps/facets/Executor.sol";

pragma solidity 0.8.24;

contract TestExecutor is ExecutorFacet {
    /// @dev Since we don't have access to the new BLOBHASH opecode we need to leverage a static call to a yul contract
    /// that calls the opcode via a verbatim call. This should be swapped out once there is solidity support for the
    /// new opcode.
    function _getBlobVersionedHash(uint256 _index) internal virtual override view returns (bytes32 versionedHash) {
        (bool success, bytes memory data) = s.blobVersionedHashRetriever.staticcall(abi.encode(_index));
        require(success, "vc");
        versionedHash = abi.decode(data, (bytes32));
    }
}
