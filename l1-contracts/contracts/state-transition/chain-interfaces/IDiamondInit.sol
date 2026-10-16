// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

interface IDiamondInit {
    /// @notice ZK chain diamond contract initialization.
    /// @dev The two arguments are the ONLY per-chain data a chain is created with; everything
    ///      else is read from the ChainTypeManager — which is simply `msg.sender`, since the CTM
    ///      is the one deploying the diamond proxy (and delegatecall preserves the sender) — and
    ///      from the genesis registry / bridgehub it points at.
    /// @param _chainId The chain id of the new chain.
    /// @param _admin The address to be set as the chain's admin.
    function initialize(uint256 _chainId, address _admin) external returns (bytes32);
}
