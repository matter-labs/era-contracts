// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

interface IDiamondInit {
    /// @notice The VM flavour this initializer genesis-installs — the SINGLE source of VM
    ///         identity for a release: the CTM validates it against its own flavour when the
    ///         release is pinned, and the upgrade composer derives the L2 tx type from it.
    // solhint-disable-next-line func-name-mixedcase
    function IS_ZKSYNC_OS() external view returns (bool);

    /// @notice ZK chain diamond contract initialization.
    /// @dev The two arguments are the ONLY per-chain data a chain is created with; everything
    ///      else is read from the ChainTypeManager — which is simply `msg.sender`, since the CTM
    ///      is the one deploying the diamond proxy (and delegatecall preserves the sender) — and
    ///      from the genesis registry / bridgehub it points at.
    /// @param _chainId The chain id of the new chain.
    /// @param _admin The address to be set as the chain's admin.
    function initialize(uint256 _chainId, address _admin) external returns (bytes32);
}
