// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {SystemContractsCaller} from "../common/libraries/SystemContractsCaller.sol";
import {L2_DEPLOYER_SYSTEM_CONTRACT_ADDR} from "../common/L2ContractAddresses.sol";
import {IContractDeployer} from "../common/libraries/L2ContractHelper.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Contract used to depploy only whitelisted bytecodes.
/// @dev Users are not allowed to deploy generic contracts on Gateway in order to 
/// ensure smooth transition in the future for a special-purpose version.
contract WhitelistedBytecodeFactory is Ownable2Step {
    /// @notice Emitted when an admin is deployed on the L2.
    /// @param admin The address of the newly deployed admin.
    event AdminDeployed(address indexed admin);

    mapping(bytes32 bytecodeHash => bool isAllowed) isBytecodeHashAllowed;

    constructor(address _initialOwner) {
        _transferOwnership(_initialOwner);
    }

    function allowBytecodeHash(bytes32 _hash, bool _isAllowed) public {
        isBytecodeHashAllowed[_hash] = _isAllowed;

        // todo: event
    }


    function deployContract(
        bytes32 _salt,
        bytes32 _bytecodeHash, 
        bytes memory _constructorParams
    ) external returns (address addr) {
        (bool success, bytes memory returndata) = SystemContractsCaller.systemCallWithReturndata(
            uint32(gasleft()),
            L2_DEPLOYER_SYSTEM_CONTRACT_ADDR,
            0,
            abi.encodeCall(
                IContractDeployer.create2,
                (_salt, _bytecodeHash, _constructorParams)
            )
        );

        // The deployment should be successful and return the address of the proxy
        if (!success) {
            // revert DeployFailed();
        }

        addr = abi.decode(returndata, (address));

        // todo: emit event
    }
}
