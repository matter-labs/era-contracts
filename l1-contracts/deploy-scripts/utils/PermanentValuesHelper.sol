// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {stdToml} from "forge-std/StdToml.sol";

/// @title PermanentValuesHelper
/// @notice A small helper library to read create2 factory values from permanent-values.toml
library PermanentValuesHelper {
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    Vm internal constant vm = Vm(VM_ADDRESS);

    bytes32 internal constant DEFAULT_SALT = 0x88923c4cbe9c208bdd041f7c19b2d0f7e16d312e3576f17934dd390b7a2c5cc5;

    using stdToml for string;

    /// @notice Returns the path to the permanent values TOML file
    /// @return The full path to the permanent values file
    function getPermanentValuesPath() internal view returns (string memory) {
        return string.concat(vm.projectRoot(), vm.envString("PERMANENT_VALUES_INPUT"));
    }

    /// @notice Reads create2 factory values from the permanent values TOML file
    /// @param permanentValuesPath The path to the permanent values file
    /// @return create2FactoryAddr The create2 factory address (if configured)
    /// @return create2FactorySalt The create2 factory salt
    function getPermanentValues(
        string memory permanentValuesPath
    ) internal view returns (address create2FactoryAddr, bytes32 create2FactorySalt) {
        string memory permanentValuesToml = vm.readFile(permanentValuesPath);
        create2FactorySalt = permanentValuesToml.readBytes32("$.permanent_contracts.create2_factory_salt");
        if (vm.keyExistsToml(permanentValuesToml, "$.permanent_contracts.create2_factory_addr")) {
            create2FactoryAddr = permanentValuesToml.readAddress("$.permanent_contracts.create2_factory_addr");
        }
    }

    /// @notice Convenience function to get permanent values without providing the path
    /// @return create2FactoryAddr The create2 factory address (if configured)
    /// @return create2FactorySalt The create2 factory salt
    function getPermanentValues() internal view returns (address create2FactoryAddr, bytes32 create2FactorySalt) {
        return getPermanentValues(getPermanentValuesPath());
    }

    /// @notice Creates the permanent-values.toml file with defaults if it is missing
    /// or if the create2_factory_salt key is absent.
    function createPermanentValuesIfNeeded() internal {
        string memory permanentValuesPath = getPermanentValuesPath();
        if (vm.isFile(permanentValuesPath)) {
            string memory toml = vm.readFile(permanentValuesPath);
            bool hasSalt = vm.keyExistsToml(toml, "$.permanent_contracts.create2_factory_salt");
            bool hasAddr = vm.keyExistsToml(toml, "$.permanent_contracts.create2_factory_addr");
            address create2FactoryAddr = hasAddr
                ? toml.readAddress("$.permanent_contracts.create2_factory_addr")
                : address(0);
            if (hasSalt && hasAddr && create2FactoryAddr.code.length > 0) {
                return; // Permanent values are already set and valid
            }
        }
        savePermanentValues(address(0), DEFAULT_SALT);
    }

    /// @notice Writes create2 factory address and salt to the permanent values file
    /// @param _create2FactoryAddr The create2 factory address
    /// @param _create2FactorySalt The create2 factory salt
    function savePermanentValues(address _create2FactoryAddr, bytes32 _create2FactorySalt) internal {
        vm.serializeString("permanent_contracts", "create2_factory_salt", vm.toString(_create2FactorySalt));
        string memory inner = vm.serializeAddress("permanent_contracts", "create2_factory_addr", _create2FactoryAddr);
        string memory toml = vm.serializeString("permanent_contracts_root", "permanent_contracts", inner);
        vm.writeToml(toml, getPermanentValuesPath());
    }

    /// @notice Reads the legacy Gateway chain ID from the permanent values TOML file
    /// @param vm The Forge VM instance
    /// @param permanentValuesPath The path to the permanent values file
    /// @return legacyGwChainId The legacy Gateway chain ID (0 if not configured)
    function getLegacyGwChainId(
        Vm vm,
        string memory permanentValuesPath
    ) internal view returns (uint256 legacyGwChainId) {
        string memory permanentValuesToml = vm.readFile(permanentValuesPath);
        if (vm.keyExistsToml(permanentValuesToml, "$.legacy_gateway.chain_id")) {
            legacyGwChainId = permanentValuesToml.readUint("$.legacy_gateway.chain_id");
        }
    }

    /// @notice Convenience function to get legacy GW chain ID without providing the path
    /// @param vm The Forge VM instance
    /// @return legacyGwChainId The legacy Gateway chain ID (0 if not configured)
    function getLegacyGwChainId(Vm vm) internal view returns (uint256 legacyGwChainId) {
        string memory permanentValuesPath = getPermanentValuesPath();
        return getLegacyGwChainId(vm, permanentValuesPath);
    }
}
