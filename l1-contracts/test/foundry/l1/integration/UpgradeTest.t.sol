// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {EcosystemUpgrade} from "deploy-scripts/upgrade/EcosystemUpgrade.s.sol";
import {ChainUpgrade} from "deploy-scripts/upgrade/ChainUpgrade.s.sol";
import {Call} from "contracts/governance/Common.sol";
import {Test} from "forge-std/Test.sol";

string constant ECOSYSTEM_INPUT = "/test/foundry/l1/integration/upgrade-envs/script-config/mainnet.toml";
string constant ECOSYSTEM_OUTPUT  = "/test/foundry/l1/integration/upgrade-envs/script-out/mainnet.toml";
string constant CHAIN_INPUT = "/test/foundry/l1/integration/upgrade-envs/script-config/mainnet-era.toml";
string constant CHAIN_OUTPUT = "/test/foundry/l1/integration/upgrade-envs/script-out/mainnet-era.toml";


contract UpgradeTest is Test {

    EcosystemUpgrade generateUpgradeData;
    ChainUpgrade chainUpgrade;

    function setUp() public {
        generateUpgradeData = new EcosystemUpgrade();
        chainUpgrade = new ChainUpgrade();
    }

    function test_MainnetFork() public {
        // Firstly, we deploy all the contracts. 
        generateUpgradeData.prepareEcosystemContracts(
            ECOSYSTEM_INPUT,
            ECOSYSTEM_OUTPUT
        );

        // For chain, we have deployed the DA validator contracts
        // and also updated the chain admin.
        // IMPORTANT: for erc20-based chains with token multiplier setter
        // this should be coordinated with the server.
        chainUpgrade.prepareChain(
            ECOSYSTEM_INPUT,
            ECOSYSTEM_OUTPUT,
            CHAIN_INPUT,
            CHAIN_OUTPUT
        );

        // Now, some time has passed and we are ready to start the upgrade of the 
        // ecosystem.
        // Stage 1 of the upgrade:
        // - accept all the ownerships of the contracts
        // - set the new upgrade data for chains

        // FIXME: how do we prevent the initial owner from front-running and changing
        // the address of the new owner?
        governanceMulticall(generateUpgradeData.getOwnerAddress(), generateUpgradeData.provideAcceptOwnershipCalls());
    }

    /// @dev This is a contract that is used for additional visibility of transactions
    /// that the decentralized governance should do.
    function governanceMulticall(address governanceAddr, Call[] memory calls) internal {
        // How the governance is implemented is out of scope here
        vm.startBroadcast(governanceAddr);

        for(uint256 i = 0; i < calls.length; i++) {
            Call memory call = calls[i];

            (bool success, bytes memory data) = payable(call.target).call{value: call.value}(call.data);
            require(success, "Multicall failed");
        }

        vm.stopBroadcast();
    }
}
