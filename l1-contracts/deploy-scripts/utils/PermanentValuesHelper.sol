// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {stdToml} from "forge-std/StdToml.sol";

/// @title PermanentValuesHelper
/// @notice A helper library to read and write create2 factory values from permanent-values.toml
library PermanentValuesHelper {
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    Vm internal constant vm = Vm(VM_ADDRESS);

    bytes32 internal constant DEFAULT_SALT = 0x88923c4cbe9c208bdd041f7c19b2d0f7e16d312e3576f17934dd390b7a2c5cc5;
    address internal constant DETERMINISTIC_CREATE2_ADDRESS = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    string internal constant CREATE2_FACTORY_SALT_ENV = "CREATE2_FACTORY_SALT";

    using stdToml for string;

    /// @notice Convenience function to get permanent values without providing the path
    /// @return create2FactoryAddr The deterministic create2 factory address
    /// @return create2FactorySalt The create2 factory salt
    function getPermanentValues() internal view returns (address create2FactoryAddr, bytes32 create2FactorySalt) {
        create2FactoryAddr = DETERMINISTIC_CREATE2_ADDRESS;
        create2FactorySalt = vm.envOr(CREATE2_FACTORY_SALT_ENV, DEFAULT_SALT);
    }
}
