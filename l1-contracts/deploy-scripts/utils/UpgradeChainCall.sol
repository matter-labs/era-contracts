// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";

/// @title Upgrade-call encoder for the chain diamonds this tooling supports.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice From v35 the chain reads the cut from its own ChainTypeManager, so the call carries no
///         cut at all. Chains on earlier versions are not supported.
/// @dev Calling the wrong shape hits the DiamondProxy fallback and reverts with `"F"`, so the
///      check is on the version the chain is CURRENTLY on, never the one it moves to.
library UpgradeChainCall {
    uint256 internal constant V35_THRESHOLD = uint256(35) << 32;

    /// @notice The cut-READING upgrade call of a chain on `_protocolVersion`.
    function encode(address _chainAddress, uint256 _protocolVersion) internal pure returns (bytes memory) {
        require(_protocolVersion >= V35_THRESHOLD, "chain predates the cut-reading entrypoint");
        return abi.encodeCall(IAdmin.upgradeChainFromVersion, (_chainAddress, _protocolVersion));
    }
}
