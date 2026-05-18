// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StealthShadowAccount} from "./StealthShadowAccount.sol";

/**
 * @title ShadowAccountFactory
 * @notice L1 factory that CREATE2-deploys `StealthShadowAccount` instances with caller-
 *         supplied `(salt, ownerChainId, ownerAddress)`. Permissionless: anyone may
 *         deploy a shadow on behalf of any (owner, salt) pair. Deployment is idempotent —
 *         the address is determined entirely by the inputs, and re-deploys revert.
 *
 *         The trusted execution surface is baked in at factory construction time: every
 *         shadow it deploys points at the same `INTEROP_HANDLER`. This guarantees that
 *         when private L1→L2 interop is wired up, the handler that drives stealth shadows
 *         on L1 is fixed and auditable, not user-controlled.
 */
contract ShadowAccountFactory {
    /// @notice L1 InteropHandler that all stealth shadows deployed by this factory will trust.
    address public immutable INTEROP_HANDLER;

    event StealthShadowDeployed(
        bytes32 indexed salt,
        uint256 indexed ownerChainId,
        address indexed ownerAddress,
        address shadowAccount
    );

    error DeploymentFailed();

    constructor(address _interopHandler) {
        INTEROP_HANDLER = _interopHandler;
    }

    /**
     * @notice Deploy a `StealthShadowAccount` for `(salt, ownerChainId, ownerAddress)`.
     * Reverts if a contract is already deployed at the computed address (CREATE2 collision).
     */
    function deploy(bytes32 _salt, uint256 _ownerChainId, address _ownerAddress)
        external
        returns (address)
    {
        StealthShadowAccount sa = new StealthShadowAccount{salt: _salt}(
            _ownerChainId,
            _ownerAddress,
            INTEROP_HANDLER
        );

        address expected = computeAddress(_salt, _ownerChainId, _ownerAddress);
        if (address(sa) != expected) revert DeploymentFailed();

        emit StealthShadowDeployed(_salt, _ownerChainId, _ownerAddress, address(sa));
        return address(sa);
    }

    /**
     * @notice Compute the deterministic address of the `StealthShadowAccount` for the
     * given `(salt, ownerChainId, ownerAddress)`. Has no side effects; callers can pre-
     * compute the stealth address before any deployment happens.
     */
    function computeAddress(bytes32 _salt, uint256 _ownerChainId, address _ownerAddress)
        public
        view
        returns (address)
    {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(StealthShadowAccount).creationCode,
                abi.encode(_ownerChainId, _ownerAddress, INTEROP_HANDLER)
            )
        );
        return address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), address(this), _salt, initCodeHash))
                )
            )
        );
    }

    /**
     * @notice Returns true iff a contract is already deployed at the address that
     * `(salt, ownerChainId, ownerAddress)` would CREATE2 to.
     */
    function isDeployed(bytes32 _salt, uint256 _ownerChainId, address _ownerAddress)
        external
        view
        returns (bool)
    {
        address predicted = computeAddress(_salt, _ownerChainId, _ownerAddress);
        return predicted.code.length > 0;
    }
}
