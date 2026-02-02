// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {Vm} from "forge-std/Vm.sol";

import {EcosystemUpgrade_v31} from "../../../../deploy-scripts/upgrade/v31/EcosystemUpgrade_v31.s.sol";
// import {DefaultChainUpgrade} from "../../../../deploy-scripts/upgrade/default_upgrade/DefaultChainUpgrade.s.sol";
import {Call} from "contracts/governance/Common.sol";
import {Test} from "forge-std/Test.sol";
// import {DefaultCTMUpgrade} from "../../../../deploy-scripts/upgrade/default_upgrade/DefaultCTMUpgrade.s.sol";
import {CTMUpgrade_v31} from "../../../../deploy-scripts/upgrade/v31/CTMUpgrade_v31.s.sol";
import {ChainUpgrade_v31} from "../../../../deploy-scripts/upgrade/v31/ChainUpgrade_v31.s.sol";
import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {GetDiamondCutData} from "../../../../deploy-scripts/utils/GetDiamondCutData.sol";

contract UpgradeIntegrationTestBase is Test {
    using stdToml for string;

    uint256 chainId;

    EcosystemUpgrade_v31 ecosystemUpgrade;
    CTMUpgrade_v31 ctmUpgrade;
    ChainUpgrade_v31 chainUpgrade;

    // For now, this test is testing "stage" - as mainnet wasn't updated yet.
    string public ECOSYSTEM_INPUT = "file_1.toml";
    string public ECOSYSTEM_UPGRADE_INPUT = "/upgrade-envs/v0.31.0-interopB/shared.toml";
    string public PERMANENT_VALUES_INPUT;
    string public ECOSYSTEM_OUTPUT = "file_3.toml";
    string public CTM_INPUT = "/upgrade-envs/v0.31.0-interopB/shared.toml";
    string public CTM_OUTPUT = "/test/foundry/l1/integration/upgrade-envs/script-out/mainnet-gateway.toml";
    string public CHAIN_INPUT;
    string public CHAIN_OUTPUT;

    function setupUpgrade(bool skipFactoryDepsCheck) public {
        ecosystemUpgrade = new EcosystemUpgrade_v31();
        ecosystemUpgrade.initialize(PERMANENT_VALUES_INPUT, ECOSYSTEM_UPGRADE_INPUT, ECOSYSTEM_INPUT, ECOSYSTEM_OUTPUT);
        ecosystemUpgrade.deployNewEcosystemContractsL1();
        chainUpgrade = new ChainUpgrade_v31();
        ctmUpgrade = new CTMUpgrade_v31();
        ctmUpgrade.setSkipFactoryDepsCheck_TestOnly(skipFactoryDepsCheck);
        ctmUpgrade.initialize(PERMANENT_VALUES_INPUT, CTM_INPUT, CTM_OUTPUT);
        ctmUpgrade.setNewProtocolVersion(SemVer.packSemVer(0, 32, 0));

        console.log("Preparing ecosystem upgrade");
        ecosystemUpgrade.prepareEcosystemUpgrade();

        console.log("Preparing ctm upgrade");
        ctmUpgrade.prepareCTMUpgrade();

        console.log("Preparing chain for the upgrade");
        chainUpgrade.prepareChain(chainId, PERMANENT_VALUES_INPUT);
    }

    function internalTest() internal {
        vm.recordLogs();
        (
            Call[] memory upgradeGovernanceStage0Calls,
            Call[] memory upgradeGovernanceStage1Calls,
            Call[] memory upgradeGovernanceStage2Calls
        ) = ecosystemUpgrade.prepareDefaultGovernanceCalls();

        (
            Call[] memory upgradeCTMStage0Calls,
            Call[] memory upgradeCTMStage1Calls,
            Call[] memory upgradeCTMStage2Calls
        ) = ctmUpgrade.prepareDefaultGovernanceCalls();

        // kl todo add GW calls here.

        console.log("Starting ecosystem upgrade stage 0!");
        governanceMulticall(ecosystemUpgrade.getOwnerAddress(), upgradeGovernanceStage0Calls);

        console.log("Starting ctm upgrade stage 0!");
        governanceMulticall(ctmUpgrade.getOwnerAddress(), upgradeCTMStage0Calls);

        // console.log("proxy admin owner", IOwnable(ecosystemUpgrade.getDiscoveredBridgehub().transparentProxyAdmin).owner());

        console.log("Starting ecosystem upgrade stage 1!");
        governanceMulticall(ecosystemUpgrade.getOwnerAddress(), upgradeGovernanceStage1Calls);

        console.log("Starting ctm upgrade stage 1!");
        governanceMulticall(ctmUpgrade.getOwnerAddress(), upgradeCTMStage1Calls);

        console.log("Starting ecosystem upgrade stage 2!");
        governanceMulticall(ecosystemUpgrade.getOwnerAddress(), upgradeGovernanceStage2Calls);

        console.log("Starting ctm upgrade stage 2!");
        governanceMulticall(ctmUpgrade.getOwnerAddress(), upgradeCTMStage2Calls);

        console.log("Ecosystem upgrade is prepared, now all the chains have to upgrade to the new version");

        console.log("Upgrading gateway");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        Diamond.DiamondCutData memory diamondCutData = GetDiamondCutData.getDiamondCutDataFromRecordedLogs(
            logs,
            ctmUpgrade.getCTMAddress()
        );

        // Now, the admin of the Era needs to call the upgrade function.
        // TODO: We do not include calls that ensure that the server is ready for the sake of brevity.
        chainUpgrade.upgradeChain(diamondCutData);

        console.log("Creating new chain");
        address admin = ctmUpgrade.getBridgehubAdmin();
        vm.startPrank(admin);
        Call memory createNewChainCall = ctmUpgrade.prepareCreateNewChainCall(555)[0];
        (bool success, bytes memory data) = payable(createNewChainCall.target).call{value: createNewChainCall.value}(
            createNewChainCall.data
        );
        require(success, "Create new chain call failed");
        vm.stopPrank();

        // TODO: here we should include tests that depoists work for upgraded chains
        // including era specific deposit/withdraw functions
        // We also may need to test that normal flow of block commit / verify / execute works (but it is hard)
        // so it was tested in e2e local environment.
    }

    /// @dev This is a contract that is used for additional visibility of transactions
    /// that the decentralized governance should do.
    function governanceMulticall(address governanceAddr, Call[] memory calls) internal {
        // How the governance is implemented is out of scope here
        vm.startBroadcast(governanceAddr);

        for (uint256 i = 0; i < calls.length; i++) {
            Call memory call = calls[i];

            (bool success, bytes memory data) = payable(call.target).call{value: call.value}(call.data);
            require(success, "Multicall failed");
        }

        vm.stopBroadcast();
    }

    function preparePermanentValues() internal {
        string memory root = vm.projectRoot();
        string memory permanentValuesInputPath = string.concat(root, PERMANENT_VALUES_INPUT);
        string memory outputDeployL1Toml = vm.readFile(string.concat(root, ECOSYSTEM_INPUT));
        string memory outputDeployCTMToml = vm.readFile(string.concat(root, CTM_INPUT));

        bytes32 create2FactorySalt = outputDeployL1Toml.readBytes32("$.contracts.create2_factory_salt");
        address create2FactoryAddr;
        if (vm.keyExistsToml(outputDeployL1Toml, "$.contracts.create2_factory_addr")) {
            create2FactoryAddr = outputDeployL1Toml.readAddress("$.contracts.create2_factory_addr");
        }
        address ctm = outputDeployCTMToml.readAddress(
            "$.deployed_addresses.state_transition.state_transition_proxy_addr"
        );
        address bytecodesSupplier = outputDeployCTMToml.readAddress(
            "$.deployed_addresses.state_transition.bytecodes_supplier_addr"
        );
        address l1Bridgehub = outputDeployL1Toml.readAddress("$.deployed_addresses.bridgehub.bridgehub_proxy_addr");
        bool isZKsyncOs = outputDeployCTMToml.readBool("$.is_zk_sync_os");

        address rollupDAManager;
        if (isZKsyncOs) {
            rollupDAManager = outputDeployCTMToml.readAddress(
                "$.deployed_addresses.blobs_zksync_os_l1_da_validator_addr"
            );
        } else {
            rollupDAManager = outputDeployCTMToml.readAddress("$.deployed_addresses.l1_rollup_da_manager");
        }
        uint256 eraChainId = outputDeployL1Toml.readUint("$.era_chain_id");

        // Serialize permanent_contracts section
        {
            vm.serializeString("permanent_contracts", "create2_factory_salt", vm.toString(create2FactorySalt));
            string memory permanent_contracts = vm.serializeAddress(
                "permanent_contracts",
                "create2_factory_addr",
                create2FactoryAddr
            );
            vm.serializeString("root2", "permanent_contracts", permanent_contracts);
        }

        // Serialize ctm_contracts section
        {
            vm.serializeAddress("ctm_contracts", "ctm_proxy_addr", ctm);
            vm.serializeAddress("ctm_contracts", "rollup_da_manager", rollupDAManager);
            string memory ctm_contracts = vm.serializeAddress(
                "ctm_contracts",
                "l1_bytecodes_supplier_addr",
                bytecodesSupplier
            );
            vm.serializeString("root2", "ctm_contracts", ctm_contracts);
        }

        // Serialize core_contracts section
        {
            string memory core_contracts = vm.serializeAddress("core_contracts", "bridgehub_proxy_addr", l1Bridgehub);
            vm.serializeString("root2", "core_contracts", core_contracts);
        }

        // Serialize chain2 section
        {
            string memory chain2 = vm.serializeUint("chain2", "chain_id", eraChainId);
            vm.serializeString("root2", "chain2", chain2);
        }

        // Write the final TOML
        string memory permanentValuesToml2 = vm.serializeUint("root2", "era_chain_id", eraChainId);
        vm.writeToml(permanentValuesToml2, permanentValuesInputPath);
    }
}
