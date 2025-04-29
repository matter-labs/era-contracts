// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {ChainAdmin} from "./ChainAdmin.sol";
import {RestrictionValidator} from "./restriction/RestrictionValidator.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Contract used to deploy ChainAdmin contracts on L2.
/// @dev It can be used to ensure that certain L2 admins are deployed with
/// predefined restrictions. E.g. it can be used to deploy admins that ensure that
/// a chain is a permanent rollup.
/// @dev This contract is expected to be deployed in zkEVM (L2) environment.
/// @dev The contract is immutable, in case the restrictions need to be changed,
/// a new contract should be deployed.
contract L2AdminFactory {
    /// @notice Emitted when an admin is deployed on the L2.
    /// @param admin The address of the newly deployed admin.
    event AdminDeployed(address indexed admin);

    /// @dev We use storage instead of immutable variables due to the
    /// specifics of the zkEVM environment, where storage is actually cheaper.
    address[] public requiredRestrictions;

    constructor(address[] memory _requiredRestrictions) {
        _validateRestrictions(_requiredRestrictions);
        requiredRestrictions = _requiredRestrictions;
    }

    /// @notice Deploys a new L2 admin contract.
    /// @return admin The address of the deployed admin contract.
    // solhint-disable-next-line gas-calldata-parameters
    function deployAdmin(address[] memory _additionalRestrictions) external returns (address admin) {
        // Even though the chain admin will likely perform similar checks,
        // we keep those here just in case, since it is not expensive, while allowing to fail fast.
        _validateRestrictions(_additionalRestrictions);
        uint256 cachedRequired = requiredRestrictions.length;
        uint256 cachedAdditional = _additionalRestrictions.length;
        address[] memory restrictions = new address[](cachedRequired + cachedAdditional);

        unchecked {
            for (uint256 i = 0; i < cachedRequired; ++i) {
                restrictions[i] = requiredRestrictions[i];
            }
            for (uint256 i = 0; i < cachedAdditional; ++i) {
                restrictions[cachedRequired + i] = _additionalRestrictions[i];
            }
        }

        // Note, that we are using CREATE instead of CREATE2 to prevent
        // an attack where malicious deployer could select malicious `seed1` and `seed2` where
        // this factory with `seed1` produces the same address as some other random factory with `seed2`,
        // allowing to deploy a malicious contract.
        admin = address(new ChainAdmin(restrictions));

        emit AdminDeployed(address(admin));
    }

    /// @notice Checks that the provided list of restrictions is correct.
    /// @param _restrictions List of the restrictions to check.
    /// @dev In case either of the restrictions is not correct, the function reverts.
    function _validateRestrictions(address[] memory _restrictions) internal view {
        unchecked {
            uint256 length = _restrictions.length;
            for (uint256 i = 0; i < length; ++i) {
                RestrictionValidator.validateRestriction(_restrictions[i]);
            }
        }
    }
}
