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

    /// @notice The L2 genesis transaction `genesisUpgrade` commits for a chain created at
    ///         `_release` — the FINAL transaction, exactly as the chain stores its hash.
    /// @dev THE composition view, the genesis counterpart of `IDefaultUpgrade.l2UpgradeTx`: free
    /// of diamond-storage reads, so it is called directly on this contract rather than through a
    /// chain, and it runs the same construction the execution path runs.
    /// @param _release The `CTMRelease` the chain is created at.
    /// @param _bridgehub The Bridgehub of the ecosystem the chain belongs to.
    /// @param _chainId The chain to compose for.
    /// @param _protocolVersion The packed version the chain starts at.
    function genesisUpgradeTx(
        address _release,
        address _bridgehub,
        uint256 _chainId,
        uint256 _protocolVersion
    ) external view returns (L2CanonicalTransaction memory);
}
