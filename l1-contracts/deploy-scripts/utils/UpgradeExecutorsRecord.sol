// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";

/// @notice How a core-side run CREATE2-deployed the core executor.
/// @param coreExecutor The `CoreUpgradeExecutor`.
/// @param create2Salt The salt it was deployed under.
/// @param initialOwner Its constructor `_initialOwner`.
/// @param proxyAdmin Its constructor `_proxyAdmin`: the ecosystem `ProxyAdmin`.
struct CoreExecutorDeployment {
    address coreExecutor;
    bytes32 create2Salt;
    address initialOwner;
    address proxyAdmin;
}

/// @notice How a CTM-side run CREATE2-deployed the CTM executor.
/// @param ctmExecutor The `CTMUpgradeExecutor`.
/// @param create2Salt The salt it was deployed under.
/// @param initialOwner Its constructor `_initialOwner`.
/// @param chainTypeManager Its constructor `_ctm`.
/// @param ctmProxyAdmin Its constructor `_ctmProxyAdmin`.
// solhint-disable-next-line gas-struct-packing
struct CTMExecutorDeployment {
    address ctmExecutor;
    bytes32 create2Salt;
    address initialOwner;
    address chainTypeManager;
    address ctmProxyAdmin;
}

/// @notice Serializes the `[upgrade_executors]` section every run that deploys an upgrade executor
///         writes: each executor's address with its CREATE2 salt and ORIGINAL constructor
///         arguments, so its construction stays re-derivable after its owner moves.
///         protocol-ops reads it (`--executor-record`); see "Provenance and validation" in
///         {docs/registry-driven-upgrades.md}.
/// @dev The returned JSON is meant for `vm.serializeString(<root>, "upgrade_executors", json)`. One
///      serialization object for both sides: where a single process runs both (the Foundry harnesses),
///      each output then carries every executor deployed so far rather than the last side's alone.
library UpgradeExecutorsRecord {
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    // solhint-disable-next-line const-name-snakecase
    Vm internal constant vm = Vm(VM_ADDRESS);

    string internal constant RECORD_KEY = "upgrade_executors";

    /// @param _d The core-side deployment.
    /// @return json The `upgrade_executors` object with `core_executor`.
    function serializeCore(CoreExecutorDeployment memory _d) internal returns (string memory json) {
        vm.serializeAddress("core_executor_record", "address", _d.coreExecutor);
        vm.serializeBytes32("core_executor_record", "create2_salt", _d.create2Salt);
        vm.serializeAddress("core_executor_record", "initial_owner", _d.initialOwner);
        string memory coreExecutor = vm.serializeAddress("core_executor_record", "proxy_admin", _d.proxyAdmin);

        json = vm.serializeString(RECORD_KEY, "core_executor", coreExecutor);
    }

    /// @param _d The CTM-side deployment.
    /// @return json The `upgrade_executors` object with `ctm_executor`.
    function serializeCTM(CTMExecutorDeployment memory _d) internal returns (string memory json) {
        vm.serializeAddress("ctm_executor_record", "address", _d.ctmExecutor);
        vm.serializeBytes32("ctm_executor_record", "create2_salt", _d.create2Salt);
        vm.serializeAddress("ctm_executor_record", "initial_owner", _d.initialOwner);
        vm.serializeAddress("ctm_executor_record", "chain_type_manager", _d.chainTypeManager);
        string memory ctmExecutor = vm.serializeAddress("ctm_executor_record", "ctm_proxy_admin", _d.ctmProxyAdmin);

        json = vm.serializeString(RECORD_KEY, "ctm_executor", ctmExecutor);
    }
}
