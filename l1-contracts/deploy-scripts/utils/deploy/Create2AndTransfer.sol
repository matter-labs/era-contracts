// SPDX-License-Identifier: MIT

import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";

pragma solidity 0.8.28;

/// @title Create2AndTransfer
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Allows to deterministically create a contract with a fixed owner.
contract Create2AndTransfer {
    /// @notice The address of the contract deployed during inside the constructor.
    // This contract is deployed (and force-included in AllContractsHashes), so the
    // public getter name is part of a tracked ABI.
    // solhint-disable-next-line immutable-vars-naming
    address public immutable deployedAddress;

    constructor(bytes memory bytecode, bytes32 salt, address owner) {
        address addr;
        assembly {
            addr := create2(0x0, add(bytecode, 0x20), mload(bytecode), salt)
        }

        // `type(Create2AndTransfer).creationCode` is fed to CREATE2 by `Create2FactoryUtils`, so
        // switching this to a custom error would change the creation code and therefore every
        // address derived from it.
        // solhint-disable-next-line gas-custom-errors
        require(addr != address(0), "Create2: Failed on deploy");
        IOwnable(addr).transferOwnership(owner);

        deployedAddress = addr;
    }
}
