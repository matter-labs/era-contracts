// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";

/// @notice How a run CREATE2-deployed one contract through `DeployUtils`.
/// @param deployed Where it landed.
/// @param contractName The artifact contract name its creation code was read from.
/// @param create2Factory The factory it was deployed through.
/// @param create2Salt The salt it was deployed under.
/// @param constructorArgs Exactly the bytes appended to its creation code.
// solhint-disable-next-line gas-struct-packing
struct MemberDeployment {
    address deployed;
    string contractName;
    address create2Factory;
    bytes32 create2Salt;
    bytes constructorArgs;
}

/// @notice Serializes the `[member_deployments]` section every upgrade prepare writes: each contract
///         the run deployed through `deploySimpleContract` or as a proxy implementation, keyed by
///         its address, with what re-derives that address. protocol-ops re-derives every member a
///         package newly installs from it; see "Provenance and validation" in
///         {docs/registry-driven-upgrades.md}.
/// @dev The returned JSON is meant for `vm.serializeString(<root>, "member_deployments", json)`.
library MemberDeploymentsRecord {
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    // solhint-disable-next-line const-name-snakecase
    Vm internal constant vm = Vm(VM_ADDRESS);

    string internal constant RECORD_KEY = "member_deployments";

    /// @param _deployments The run's deployments.
    /// @return json The `member_deployments` object, `{}` when the run deployed nothing.
    function serialize(MemberDeployment[] memory _deployments) internal returns (string memory json) {
        // Serialization objects are process-global and one process may run several prepares (the
        // Foundry harnesses), so the object is reset rather than appended to.
        json = vm.serializeJson(RECORD_KEY, "{}");
        uint256 length = _deployments.length;
        for (uint256 i = 0; i < length; ++i) {
            MemberDeployment memory d = _deployments[i];
            string memory deployedKey = vm.toString(d.deployed);
            string memory entryKey = string.concat(RECORD_KEY, ".", deployedKey);
            vm.serializeJson(entryKey, "{}");
            vm.serializeString(entryKey, "contract", d.contractName);
            vm.serializeAddress(entryKey, "create2_factory", d.create2Factory);
            vm.serializeBytes32(entryKey, "create2_salt", d.create2Salt);
            string memory entry = vm.serializeBytes(entryKey, "constructor_args", d.constructorArgs);
            json = vm.serializeString(RECORD_KEY, deployedKey, entry);
        }
    }
}
