// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IShadowAccountFactory} from "./IShadowAccountFactory.sol";
import {ShadowAccount} from "./ShadowAccount.sol";

/// @title ShadowAccountFactory
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Deploys ShadowAccount instances via CREATE2, ensuring deterministic addresses
///         derived from the owner's ERC-7930 encoded identity.
/// @dev One ShadowAccount per owner per chain. The salt is `keccak256(owner)` which encodes
///      both the owner's home chain ID and address, so the same owner gets different shadow
///      accounts on different deployment chains but consistent addresses given the same factory.
/// @dev No constructor or immutables — L2 contracts in zksync OS do not support them.
///      The creation code hash is computed inline when needed.
contract ShadowAccountFactory is IShadowAccountFactory {
    /// @inheritdoc IShadowAccountFactory
    function getOrDeployShadowAccount(bytes calldata _owner) external returns (address account) {
        account = this.predictAddress(_owner);

        // If already deployed, return the existing account.
        if (account.code.length > 0) {
            return account;
        }

        // Deploy via CREATE2 with deterministic salt.
        bytes32 salt = keccak256(_owner);
        ShadowAccount newAccount = new ShadowAccount{salt: salt}();
        assert(address(newAccount) == account);

        // Initialize with the owner identity.
        newAccount.initialize(_owner);

        emit ShadowAccountDeployed(account, _owner);
    }

    /// @inheritdoc IShadowAccountFactory
    function predictAddress(bytes calldata _owner) external view returns (address predicted) {
        bytes32 salt = keccak256(_owner);
        bytes32 codeHash = keccak256(type(ShadowAccount).creationCode);
        predicted = address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, codeHash))
                )
            )
        );
    }
}
