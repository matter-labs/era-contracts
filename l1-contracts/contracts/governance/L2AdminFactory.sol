// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {ChainAdmin} from "./ChainAdmin.sol";
import {ZeroAddress} from "../common/L1ContractErrors.sol";

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
        _validateZeroAddress(_requiredRestrictions);
        requiredRestrictions = _requiredRestrictions;
    }

    /// @notice Deploys a new L2 admin contract.
    /// @return admin The address of the deployed admin contract.
    function deployAdmin(address[] memory _additionalRestrictions, bytes32 _salt) external returns (address admin) {
        _validateZeroAddress(_additionalRestrictions);

        address[] memory restrictions = new address[](requiredRestrictions.length + _additionalRestrictions.length);
        uint256 cachedRequired = requiredRestrictions.length;
        for (uint256 i = 0; i < cachedRequired; ++i) {
            restrictions[i] = requiredRestrictions[i];
        }
        uint256 cachedAdditional = _additionalRestrictions.length;
        for (uint256 i = 0; i < cachedAdditional; ++i) {
            restrictions[requiredRestrictions.length + i] = _additionalRestrictions[i];
        }

        admin = address(new ChainAdmin{salt: _salt}(restrictions));
    }

    function _validateZeroAddress(address[] memory _restrictions) internal view {
        unchecked {
            uint256 length = _restrictions.length;
            for(uint256 i = 0; i < length; ++i) {
                if (_restrictions[i] == address(0)) {
                    revert ZeroAddress();
                }
            }
        }
    }
}
