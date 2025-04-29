// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {stdToml} from "forge-std/StdToml.sol";
import {Script, console2 as console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";

import {SYSTEM_CONTRACTS_OFFSET} from "contracts/common/L2ContractAddresses.sol";

address constant EVM_PREDEPLOYS_MANAGER = address(SYSTEM_CONTRACTS_OFFSET + 0x14);

interface IEvmPredeploysManager {
    function deployPredeployedContract(address contractAddress, bytes calldata constructorInput) external;
}

string constant DATA_PATH = "/deploy-scripts/evm-predeploys/evm-predeploy-datas/";

/// @notice Scripts that is used to deploy predefined EVM contracts on ZK Chains with EVM emulation support
contract DeployEvmPredeploys is Script {
    using stdToml for string;

    function run() external {
        string memory root = vm.projectRoot();
        string memory dataPath = string.concat(root, DATA_PATH);

        Vm.DirEntry[] memory entries = vm.readDir(dataPath);

        for (uint256 i = 0; i < entries.length; i++) {
            deploy(entries[i].path);
        }
    }

    function deploy(string memory configPath) internal {
        console.log(configPath);
        string memory toml = vm.readFile(configPath);

        address contractAddress = toml.readAddress("$.address");
        bytes memory constructorInput = toml.readBytes("$.constructor_input");

        vm.broadcast();
        IEvmPredeploysManager(EVM_PREDEPLOYS_MANAGER).deployPredeployedContract(contractAddress, constructorInput);
    }
}
