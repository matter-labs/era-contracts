// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {L2CanonicalTransaction} from "../common/Messaging.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice L1 genesis upgrade interface. Every chain has to process an upgrade txs at its genesis.
 * @notice This is needed to set system params like the chainId and to deploy some system contracts.
 */
interface IL1GenesisUpgrade {
    /// @dev emitted when a chain registers and a GenesisUpgrade happens
    /// @param _zkChain the address of the zk chain
    /// @param _l2Transaction the l2 genesis upgrade transaction
    /// @param _protocolVersion the current protocol version
    /// @param _factoryDeps the factory dependencies needed for the upgrade
    event GenesisUpgrade(
        address indexed _zkChain,
        L2CanonicalTransaction _l2Transaction,
        uint256 indexed _protocolVersion,
        bytes[] _factoryDeps
    );

    /// @notice The main function that will be called by the Admin facet at genesis.
    /// @param _l1GenesisUpgrade the address of the l1 genesis upgrade
    /// @param _chainId the chain id
    /// @param _protocolVersion the current protocol version
    /// @param _l1CtmDeployerAddress the address of the l1 ctm deployer
    /// @param _forceDeployments the force deployments
    /// @param _factoryDeps the factory dependencies
    function genesisUpgrade(
        address _l1GenesisUpgrade,
        uint256 _chainId,
        uint256 _protocolVersion,
        address _l1CtmDeployerAddress,
        bytes calldata _forceDeployments,
        bytes[] calldata _factoryDeps
    ) external returns (bytes32);
}
