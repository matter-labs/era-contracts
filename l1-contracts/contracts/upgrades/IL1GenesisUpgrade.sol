// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

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
    event GenesisUpgrade(
        address indexed _zkChain,
        L2CanonicalTransaction _l2Transaction,
        uint256 indexed _protocolVersion
    );

    /// @notice The main function that will be called by the Admin facet at genesis.
    /// @dev Takes no arguments: it is delegatecalled into the freshly initialized chain diamond,
    /// so the chain identity and protocol version come from that diamond's own storage, the force
    /// deployments from the release its CTM pins, and the CTM deployer from the Bridgehub.
    function genesisUpgrade() external returns (bytes32);
}
