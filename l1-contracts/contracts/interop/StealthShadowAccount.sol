// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title StealthShadowAccount
 * @notice The privacy variant of `L1ShadowAccount`. Holds funds on L1 at an address
 *         derived from `(ownerChainId, ownerAddress, salt)` via CREATE2 — where
 *         `salt = keccak256(user, secret)` is supplied by the L2 `StealthSender`.
 *
 *         Every stealth shadow for users of the same `StealthSender` shares the same
 *         `(ownerChainId, ownerAddress)` pair; the address differences come from the
 *         per-user salt. To an L1 observer, the resulting addresses look unrelated.
 *
 *         Execution is gated to a single, trusted L1 `InteropHandler` that — in the
 *         full design — only routes calls verified to have originated from
 *         `(ownerChainId, ownerAddress)` on L2 via a Merkle-proven L2→L1 message. On
 *         a sandbox where the L2 InteropCenter can't dispatch L2→L1 bundles, the
 *         handler entry point is forward-looking; funds sent here accumulate at the
 *         stealth address until that path comes online.
 */
contract StealthShadowAccount {
    /// @notice L2 chain id of the contract that owns this shadow (the StealthSender).
    uint256 public immutable OWNER_CHAIN_ID;

    /// @notice Address of the owner contract on the owner chain (the StealthSender).
    address public immutable OWNER_ADDRESS;

    /// @notice L1 InteropHandler permitted to drive execution. Must equal the handler
    /// that will route verified L2→L1 messages targeting this account.
    address public immutable INTEROP_HANDLER;

    error NotInteropHandler();
    error CallFailed(bytes returndata);

    constructor(uint256 _ownerChainId, address _ownerAddress, address _interopHandler) {
        OWNER_CHAIN_ID = _ownerChainId;
        OWNER_ADDRESS = _ownerAddress;
        INTEROP_HANDLER = _interopHandler;
    }

    /**
     * @notice Execute a single call on behalf of the remote owner. Callable only by the
     * configured InteropHandler. The handler is responsible for having verified that the
     * L2→L1 message that triggered this call originated from `(OWNER_CHAIN_ID, OWNER_ADDRESS)`.
     */
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
