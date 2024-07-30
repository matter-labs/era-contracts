// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {L2CanonicalTransaction} from "../common/Messaging.sol";

interface IL1GenesisUpgrade {
    /// @dev emitted when an chain registers and a GenesisUpgrade happens
    event GenesisUpgrade(
        address indexed _hyperchain,
        L2CanonicalTransaction _l2Transaction,
        uint256 indexed _protocolVersion,
        bytes[] _factoryDeps
    );

    function genesisUpgrade(
        address _l1GenesisUpgrade,
        uint256 _chainId,
        uint256 _protocolVersion,
        bytes calldata _forceDeployments,
        bytes[] calldata _factoryDeps
    ) external returns (bytes32);
}
