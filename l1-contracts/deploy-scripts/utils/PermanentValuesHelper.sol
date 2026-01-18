// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {stdToml} from "forge-std/StdToml.sol";

/// @title PermanentValuesHelper
/// @notice A small helper library to read create2 factory values from permanent-values.toml
library PermanentValuesHelper {
    using stdToml for string;

    /// @notice Returns the path to the permanent values TOML file
    /// @param vm The Forge VM instance
    /// @return The full path to the permanent values file
    function getPermanentValuesPath(Vm vm) internal view returns (string memory) {
        string memory root = vm.projectRoot();
        return string.concat(root, vm.envString("PERMANENT_VALUES_INPUT"));
    }

    /// @notice Reads create2 factory values from the permanent values TOML file
    /// @param vm The Forge VM instance
    /// @param permanentValuesPath The path to the permanent values file
    /// @return create2FactoryAddr The create2 factory address (if configured)
    /// @return create2FactorySalt The create2 factory salt
    function getPermanentValues(
        Vm vm,
        string memory permanentValuesPath
    ) internal view returns (address create2FactoryAddr, bytes32 create2FactorySalt) {
        string memory permanentValuesToml = vm.readFile(permanentValuesPath);
        create2FactorySalt = permanentValuesToml.readBytes32("$.permanent_contracts.create2_factory_salt");
        if (vm.keyExistsToml(permanentValuesToml, "$.permanent_contracts.create2_factory_addr")) {
            create2FactoryAddr = permanentValuesToml.readAddress("$.permanent_contracts.create2_factory_addr");
        }
    }

    /// @notice Convenience function to get permanent values without providing the path
    /// @param vm The Forge VM instance
    /// @return create2FactoryAddr The create2 factory address (if configured)
    /// @return create2FactorySalt The create2 factory salt
    function getPermanentValues(Vm vm) internal view returns (address create2FactoryAddr, bytes32 create2FactorySalt) {
        string memory permanentValuesPath = getPermanentValuesPath(vm);
        return getPermanentValues(vm, permanentValuesPath);
    }

    /// @notice Reads create2 factory values with a custom TOML path prefix
    /// @param vm The Forge VM instance
    /// @param permanentValuesPath The path to the permanent values file
    /// @param pathPrefix The TOML path prefix (e.g., "$.contracts" or "$.permanent_contracts")
    /// @return create2FactoryAddr The create2 factory address (if configured)
    /// @return create2FactorySalt The create2 factory salt
    function getPermanentValuesWithPrefix(
        Vm vm,
        string memory permanentValuesPath,
        string memory pathPrefix
    ) internal view returns (address create2FactoryAddr, bytes32 create2FactorySalt) {
        string memory permanentValuesToml = vm.readFile(permanentValuesPath);
        string memory saltPath = string.concat(pathPrefix, ".create2_factory_salt");
        string memory addrPath = string.concat(pathPrefix, ".create2_factory_addr");

        create2FactorySalt = permanentValuesToml.readBytes32(saltPath);
        if (vm.keyExistsToml(permanentValuesToml, addrPath)) {
            create2FactoryAddr = permanentValuesToml.readAddress(addrPath);
        }
    }
}
