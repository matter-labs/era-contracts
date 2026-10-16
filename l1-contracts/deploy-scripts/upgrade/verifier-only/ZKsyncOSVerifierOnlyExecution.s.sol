// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {console2} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";

import {EmergencyStageUpgradeCalldata} from "../EmergencyStageUpgradeCalldata.s.sol";

/// @notice The transactions whoever executes a {ZKsyncOSVerifierOnlyUpgrade} sends by hand, for the generate
/// pipeline's `[execution]` step (`upgrade-envs/v0.33.2-verifier/upgrade.toml`), which replays them on its fork
/// and renders `EXECUTE.md` from them. One entry point for every env, whatever owns its CTM:
/// - a ProtocolUpgradeHandler: governance stages 0-2 as ONE emergency proposal through the env's Emergency
///   Upgrade Board (`emergency-upgrade-board.json` layout, see {EmergencyStageUpgradeCalldata});
/// - a `Governance` with an EOA owner: `scheduleTransparent` then `execute` per stage, from that owner, as a
///   transaction-simulator JSON list (`[governance_operations]` of the ecosystem toml).
/// @dev Read-only on chain. Paths are relative to the l1-contracts root, starting with `/`.
contract ZKsyncOSVerifierOnlyExecution is EmergencyStageUpgradeCalldata {
    using stdToml for string;

    function writeExecution(
        string memory _permanentValues,
        string memory _upgradeInput,
        string memory _ecosystemToml,
        string memory _outputJson
    ) external {
        string memory input = vm.readFile(string.concat(vm.projectRoot(), _upgradeInput));
        string memory json;
        if (input.readBool("$.owner_is_governance")) {
            json = _governanceTransactions(_ecosystemToml);
        } else {
            EmergencyBoard memory board = _resolveBoard(_permanentValues);
            EmergencyTx[] memory txs = _buildProposal(board, _loadAllStages(_ecosystemToml));
            _logProposal(board, txs, "ALL GOVERNANCE STAGES");
            json = _proposalJson(board, txs, _ecosystemToml);
        }
        string memory path = string.concat(vm.projectRoot(), _outputJson);
        vm.writeFile(path, json);
        console2.log("Written to", path);
    }

    /// @dev The six `Governance` txs of `[governance_operations]`, in order, as a transaction-simulator list
    /// laid out as prettier formats it.
    /// Each schedule is followed directly by its execute, which needs the operations' delay to be 0.
    function _governanceTransactions(string memory _ecosystemToml) internal view returns (string memory json) {
        string memory toml = vm.readFile(string.concat(vm.projectRoot(), _ecosystemToml));
        address governance = IOwnable(toml.readAddress("$.state_transition.chain_type_manager_proxy")).owner();
        address owner = toml.readAddress("$.governance_operations.governance_owner");
        require(IOwnable(governance).owner() == owner, "Governance owner differs from governance_operations");
        require(toml.readUint("$.governance_operations.delay") == 0, "a Governance delay needs a wait between txs");
        json = "[";
        for (uint256 stage = 0; stage < GOVERNANCE_STAGE_COUNT; ++stage) {
            string memory prefix = string.concat("$.governance_operations.stage", vm.toString(stage));
            string memory operation = vm.toString(toml.readBytes32(string.concat(prefix, "_operation_id")));
            json = string.concat(
                json,
                stage == 0 ? "\n" : ",\n",
                _simulatorTx(
                    string.concat("Stage ", vm.toString(stage), ": Governance.scheduleTransparent(", operation, ", 0)"),
                    owner,
                    governance,
                    toml.readBytes(string.concat(prefix, "_schedule_calldata"))
                ),
                ",\n",
                _simulatorTx(
                    string.concat("Stage ", vm.toString(stage), ": Governance.execute(", operation, ")"),
                    owner,
                    governance,
                    toml.readBytes(string.concat(prefix, "_execute_calldata"))
                )
            );
        }
        json = string.concat(json, "\n]\n");
    }

    function _simulatorTx(
        string memory _description,
        address _from,
        address _to,
        bytes memory _data
    ) internal view returns (string memory) {
        return
            string.concat(
                '  {\n    "description": "',
                _description,
                '",\n    "network": "',
                _network(),
                '",\n    "from": "',
                vm.toString(_from),
                '",\n    "to": "',
                vm.toString(_to),
                '",\n    "data": "',
                vm.toString(_data),
                '",\n    "value": "0"\n  }'
            );
    }

    /// @dev The transaction-simulator name of the chain the script runs against.
    function _network() internal view returns (string memory) {
        if (block.chainid == 1) {
            return "mainnet";
        }
        require(block.chainid == 11155111, "no transaction-simulator network for this chain");
        return "sepolia";
    }
}
