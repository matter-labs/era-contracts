// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {ChainAdmin} from "./ChainAdmin.sol";

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
    event AdminDeployed(address admin);

    /// @dev We use storage instead of immutable variables due to the
    /// specifics of the zkEVM environment, where storage is actually cheaper.
    address[] public requiredRestrictions;

    constructor(address[] memory _requiredRestrictions) {
        requiredRestrictions = _requiredRestrictions;
    }

    /// @notice Deploys a new L2 admin contract.
    /// @return admin The address of the deployed admin contract.
    function deployAdmin(address[] calldata _additionalRestrictions, bytes32 _salt) external returns (address admin) {
        uint256 cachedRequired = requiredRestrictions.length;
        uint256 cachedAdditional = _additionalRestrictions.length;
        
        address[] memory restrictions = new address[](cachedRequired + cachedRequired);

        unchecked {
            for (uint256 i = 0; i < cachedRequired; ++i) {
                restrictions[i] = requiredRestrictions[i];
            }
            for (uint256 i = 0; i < cachedAdditional; ++i) {
                restrictions[cachedRequired + i] = _additionalRestrictions[i];
            }   
        }

        admin = address(new ChainAdmin{salt: _salt}(restrictions));
    }
}
