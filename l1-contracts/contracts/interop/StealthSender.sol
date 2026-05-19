// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title StealthSender
 * @notice L2 privacy primitive for L1 interop. Lets a user register a secret on L2 and
 *         derive a per-user `ownerHash = keccak256(user, secret)` that doubles as the
 *         CREATE2 salt for a `StealthShadowAccount` deployed by the L1 `ShadowAccountFactory`.
 *
 *         All users' stealth shadows on L1 share the same `(L2_CHAIN_ID, StealthSender)`
 *         owner pair — to an L1 observer they look like distinct, unrelated contracts
 *         that have no on-chain link back to any specific L2 caller.
 *
 *         Companion to the private L1 interop design (`l1-interop` skill, §12 privacy
 *         track). Distinct from the fresh-per-deposit `StealthProxy` variant: here the
 *         L1 stealth address is stable per user (one per secret) rather than fresh per
 *         deposit, but the privacy property (L1-side unlinkability) is the same.
 *
 *         The `ownerHashToUser` reverse mapping is used by `receiveReturn(...)` when
 *         funds are eventually returned from L1 via the (forward-looking) L1→L2 private
 *         interop bundle path. On a sandbox where L2→L1 bundle dispatch isn't available,
 *         `receiveReturn` is never invoked; the design is forward-compatible.
 */
contract StealthSender {
    /// @notice Secret committed per user. Set once via `register`; immutable afterwards.
    /// The secret itself is on-chain and readable by anyone who can query this contract —
    /// on Prividium, the read is gated by `Restrict Argument` on `secrets(address)` so
    /// only the user themselves can read their own secret. Pair with `Check Role` on
    /// `register(bytes32)` so only `BridgeUser` enrolees can register.
    mapping(address => bytes32) public secrets;

    /// @notice Reverse lookup `ownerHash → user`, used by `receiveReturn` when L1 sends
    /// funds back via the private interop return path.
    mapping(bytes32 => address) public ownerHashToUser;

    /// @notice The handler that may invoke `receiveReturn` during bundle execution.
    /// On a chain where L1→L2 private interop is wired up this would be the
    /// PrivateInteropHandler; on the sandbox it stays unset and `receiveReturn` reverts.
    address public immutable INTEROP_HANDLER;

    event SecretRegistered(address indexed user, bytes32 ownerHash);
    event ReturnReceived(bytes32 indexed ownerHash, address indexed user, uint256 amount);

    error ZeroSecret();
    error AlreadyRegistered(address user);
    error NotRegistered(address user);
    error NotInteropHandler();
    error UnknownOwnerHash(bytes32 ownerHash);
    error TransferFailed();

    constructor(address _interopHandler) {
        INTEROP_HANDLER = _interopHandler;
    }

    /**
     * @notice Commit a secret used to derive the user's stealth shadow on L1.
     * Secret is immutable once set — re-registration would change the user's L1
     * stealth address, stranding funds at the old one. If a user needs to rotate,
     * they should deploy under a new user EOA on L2 (or, on Prividium, enrol a new
     * wallet).
     */
    function register(bytes32 _secret) external {
        if (_secret == bytes32(0)) revert ZeroSecret();
        if (secrets[msg.sender] != bytes32(0)) revert AlreadyRegistered(msg.sender);

        secrets[msg.sender] = _secret;
        bytes32 ownerHash = keccak256(abi.encodePacked(msg.sender, _secret));
        ownerHashToUser[ownerHash] = msg.sender;

        emit SecretRegistered(msg.sender, ownerHash);
    }

    /**
     * @notice Returns the CREATE2 salt that the L1 `ShadowAccountFactory` should use
     * to deploy this user's stealth shadow account.
     */
    function ownerHashOf(address _user) external view returns (bytes32) {
        bytes32 secret = secrets[_user];
        if (secret == bytes32(0)) revert NotRegistered(_user);
        return keccak256(abi.encodePacked(_user, secret));
    }

    /// @notice Convenience helper — returns true iff `_user` has registered a secret.
    function isRegistered(address _user) external view returns (bool) {
        return secrets[_user] != bytes32(0);
    }

    /**
     * @notice Called by the configured InteropHandler when private interop returns
     * funds from L1. Looks up the user behind the ownerHash and forwards the ETH.
     *
     * On sandboxes where L1→L2 private interop is unavailable this never runs —
     * `INTEROP_HANDLER` is set to a placeholder and the function reverts.
     */
    function receiveReturn(bytes32 _ownerHash) external payable {
        if (msg.sender != INTEROP_HANDLER) revert NotInteropHandler();
        address user = ownerHashToUser[_ownerHash];
        if (user == address(0)) revert UnknownOwnerHash(_ownerHash);

        (bool ok, ) = user.call{value: msg.value}("");
        if (!ok) revert TransferFailed();

        emit ReturnReceived(_ownerHash, user, msg.value);
    }
}
