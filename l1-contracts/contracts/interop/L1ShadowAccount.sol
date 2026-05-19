// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice L1 smart-account counterpart of an L2 user. Adapted from PR #2177.
///
/// Aligns with the kl/interop-docs/shadow-accounts spec: a ShadowAccount executes
/// arbitrary calls on behalf of a remote-chain owner, gated by the local InteropHandler
/// (which itself only routes calls that came in via a verified L2->L1 message).
///
/// Owner identification is captured by the CREATE2 salt the handler uses
/// (`keccak256(abi.encode(l2ChainId, l2Sender))`); the account itself is owner-agnostic
/// and only trusts its handler.
contract L1ShadowAccount {
    address public immutable INTEROP_HANDLER;

    error NotInteropHandler();
    error CallFailed(bytes returndata);

    constructor() {
        INTEROP_HANDLER = msg.sender;
    }

    /// @notice Executes a single call on behalf of the remote-chain owner.
    /// Only the InteropHandler that deployed this account may invoke this.
    function executeFromHandler(address target, uint256 value, bytes calldata data)
        external
        returns (bytes memory)
    {
        if (msg.sender != INTEROP_HANDLER) revert NotInteropHandler();
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        if (!ok) revert CallFailed(ret);
        return ret;
    }

    receive() external payable {}
}
