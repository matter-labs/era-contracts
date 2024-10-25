// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {L2CanonicalTransaction} from "../common/Messaging.sol";

interface IL1GenesisUpgrade {
    /// @dev emitted when a chain registers and a GenesisUpgrade happens
    /// @param _zkChain Address of the ZK Chain
    /// @param _l2Transaction Genesis upgrade transaction
    /// @param _protocolVersion The protocol version of the deployed ZK Chain.
    /// @param _factoryDeps The factory dependencies for the chain's deployment.
    event GenesisUpgrade(
        address indexed _zkChain,
        L2CanonicalTransaction _l2Transaction,
        uint256 indexed _protocolVersion,
        bytes[] _factoryDeps
    );

    function genesisUpgrade(
        address _l1GenesisUpgrade,
        uint256 _chainId,
        uint256 _protocolVersion,
        address _l1CtmDeployerAddress,
        bytes calldata _forceDeployments,
        bytes[] calldata _factoryDeps
    ) external returns (bytes32);
}
