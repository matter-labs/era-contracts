// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {ChainAdmin} from "./ChainAdmin.sol";
<<<<<<< HEAD
import {RestrictionValidator} from "./restriction/RestrictionValidator.sol";
=======
import {ZeroAddress} from "../common/L1ContractErrors.sol";
>>>>>>> origin/sb-governance-l02

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
    event AdminDeployed(address admin);

    /// @dev We use storage instead of immutable variables due to the
    /// specifics of the zkEVM environment, where storage is actually cheaper.
    address[] public requiredRestrictions;

    constructor(address[] memory _requiredRestrictions) {
<<<<<<< HEAD
        _validateRestrctions(_requiredRestrictions);
=======
        _validateZeroAddress(_requiredRestrictions);
>>>>>>> origin/sb-governance-l02
        requiredRestrictions = _requiredRestrictions;
    }

    /// @notice Deploys a new L2 admin contract.
    /// @return admin The address of the deployed admin contract.
<<<<<<< HEAD
    // solhint-disable-next-line gas-calldata-parameters
    function deployAdmin(address[] memory _additionalRestrictions, bytes32 _salt) external returns (address admin) {
        // Even though the chain admin will likely perform similar checks, 
        // we keep those here just in case, since it is not expensive, while allowing to fail fast.
<<<<<<< HEAD
        _validateRestrctions(_additionalRestrictions);
=======
        _validateZeroAddress(_additionalRestrictions);

>>>>>>> origin/sb-governance-l02
        address[] memory restrictions = new address[](requiredRestrictions.length + _additionalRestrictions.length);
=======
    function deployAdmin(address[] calldata _additionalRestrictions, bytes32 _salt) external returns (address admin) {
>>>>>>> origin/sb-governance-n01
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

        emit AdminDeployed(admin);
    }

<<<<<<< HEAD
    /// @notice Checks that the provided list of restrictions is correct.
    /// @param _restrictions List of the restrictions to check.
    /// @dev In case either of the restrictions is not correct, the function reverts.
    function _validateRestrctions(address[] memory _restrictions) internal view {
        unchecked {
            uint256 length = _restrictions.length;
            for(uint256 i = 0; i < length; ++i) {
                RestrictionValidator.validateRestriction(_restrictions[i]);
=======
    /// @notice Checks that the provided list of restrictions does not contain
    /// any zero addresses.
    /// @param _restrictions List of the restrictions to check.
    /// @dev In case either of the restrictions is zero address, the function reverts.
    function _validateZeroAddress(address[] memory _restrictions) internal view {
        unchecked {
            uint256 length = _restrictions.length;
            for(uint256 i = 0; i < length; ++i) {
                if (_restrictions[i] == address(0)) {
                    revert ZeroAddress();
                }
>>>>>>> origin/sb-governance-l02
            }
        }
    }
}
