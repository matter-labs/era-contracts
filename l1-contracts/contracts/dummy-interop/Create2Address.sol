// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

library Create2Address {
    /*//////////////////////////////////////////////////////////////
            CREATE2 EVM FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculates the address of a deployed contract via create2 on the EVM
    /// @param _sender The account that deploys the contract.
    /// @param _salt The create2 salt.
    /// @param _bytecodeHash The hash of the init code of the new contract.
    /// @return newAddress The derived address of the account.
    function getNewAddressCreate2EVM(
        address _sender,
        bytes32 _salt,
        bytes32 _bytecodeHash
    ) internal pure returns (address newAddress) {
        bytes1 CREATE2_EVM_PREFIX = 0xff;

        bytes32 hash = keccak256(abi.encodePacked(bytes1(CREATE2_EVM_PREFIX), _sender, _salt, _bytecodeHash));

        newAddress = address(uint160(uint256(hash)));
    }
}
