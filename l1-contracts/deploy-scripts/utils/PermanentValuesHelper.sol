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

    /// @notice Returns the path to the permanent values TOML file
    /// @return The full path to the permanent values file
    function getPermanentValuesPath() internal view returns (string memory) {
        return string.concat(vm.projectRoot(), vm.envString("PERMANENT_VALUES_INPUT"));
    }

    /// @notice Reads create2 factory values.
    /// @dev Scripts always use deterministic Create2 factory address and take salt from env var.
    /// If CREATE2_FACTORY_SALT is not provided, DEFAULT_SALT is used.
    /// @param permanentValuesPath The path to the permanent values file
    /// @return create2FactoryAddr The deterministic create2 factory address
    /// @return create2FactorySalt The create2 factory salt
    function getPermanentValues(
        string memory permanentValuesPath
    ) internal view returns (address create2FactoryAddr, bytes32 create2FactorySalt) {
        permanentValuesPath;
        create2FactoryAddr = DETERMINISTIC_CREATE2_ADDRESS;
        create2FactorySalt = vm.envOr(CREATE2_FACTORY_SALT_ENV, DEFAULT_SALT);
    }

    /// @notice Convenience function to get permanent values without providing the path
    /// @return create2FactoryAddr The deterministic create2 factory address
    /// @return create2FactorySalt The create2 factory salt
    function getPermanentValues() internal view returns (address create2FactoryAddr, bytes32 create2FactorySalt) {
        return getPermanentValues(getPermanentValuesPath());
    }

    /// @notice Deprecated no-op. Create2 salt no longer comes from permanent values.
    function createPermanentValuesIfNeeded() internal {
        // no-op
    }

    /// @notice Deprecated no-op. Kept for backward compatibility.
    /// @param _create2FactoryAddr Unused. Kept for backward-compatible call sites.
    /// @param _create2FactorySalt The create2 factory salt
    function savePermanentValues(address _create2FactoryAddr, bytes32 _create2FactorySalt) internal {
        _create2FactoryAddr;
        _create2FactorySalt;
        // no-op
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
