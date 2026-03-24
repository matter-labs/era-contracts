// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {Vm} from "forge-std/Vm.sol";

import {EcosystemUpgrade_v31} from "../../../../deploy-scripts/upgrade/v31/EcosystemUpgrade_v31.s.sol";
// import {DefaultChainUpgrade} from "../../../../deploy-scripts/upgrade/default-upgrade/DefaultChainUpgrade.s.sol";
import {Call} from "contracts/governance/Common.sol";
import {Test} from "forge-std/Test.sol";
// import {DefaultCTMUpgrade} from "../../../../deploy-scripts/upgrade/default-upgrade/DefaultCTMUpgrade.s.sol";
import {CTMUpgrade_v31} from "../../../../deploy-scripts/upgrade/v31/CTMUpgrade_v31.s.sol";
import {ChainUpgrade_v31} from "../../../../deploy-scripts/upgrade/v31/ChainUpgrade_v31.s.sol";

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
    string public ECOSYSTEM_OUTPUT = "file_3.toml";
    string public CTM_INPUT = "/upgrade-envs/v0.31.0-interopB/shared.toml";
    string public CTM_OUTPUT = "/script-out/foundry-upgrade/mainnet-gateway.toml";
    string public CHAIN_INPUT;
    string public CHAIN_OUTPUT;

    function setupUpgrade(bool skipFactoryDepsCheck) public virtual {
        console.log("setupUpgrade: Creating EcosystemUpgrade_v31");
        ecosystemUpgrade = createEcosystemUpgrade();

        console.log("setupUpgrade: Reading deployment outputs for initializeWithArgs");
        string memory root = vm.projectRoot();
        vm.createDir(string.concat(root, "/script-out/foundry-upgrade"), true);
        string memory outputDeployL1Toml = vm.readFile(string.concat(root, ECOSYSTEM_INPUT));
        string memory outputDeployCTMToml = vm.readFile(string.concat(root, CTM_INPUT));

        address bridgehubProxy = outputDeployL1Toml.readAddress("$.deployed_addresses.bridgehub.bridgehub_proxy_addr");
        address ctmProxy = outputDeployCTMToml.readAddress(
            "$.deployed_addresses.state_transition.state_transition_proxy_addr"
        );
        address bytecodesSupplier = outputDeployCTMToml.readAddress(
            "$.deployed_addresses.state_transition.bytecodes_supplier_addr"
        );
        bool isZKsyncOs = outputDeployCTMToml.readBool("$.is_zk_sync_os");
        address rollupDAManager;
        if (isZKsyncOs) {
            rollupDAManager = outputDeployCTMToml.readAddress(
                "$.deployed_addresses.blobs_zksync_os_l1_da_validator_addr"
            );
        } else {
            rollupDAManager = outputDeployCTMToml.readAddress("$.deployed_addresses.l1_rollup_da_manager");
        }
        address governance = outputDeployL1Toml.readAddress("$.deployed_addresses.governance_addr");

        console.log("setupUpgrade: Initializing ecosystem upgrade");
        ecosystemUpgrade.initializeWithArgs(
            bridgehubProxy,
            ctmProxy,
            bytecodesSupplier,
            rollupDAManager,
            isZKsyncOs,
            bytes32(0),
            ECOSYSTEM_UPGRADE_INPUT,
            ECOSYSTEM_OUTPUT,
            governance
        );
        console.log("setupUpgrade: Deploying new ecosystem contracts");
        ecosystemUpgrade.deployNewEcosystemContractsL1();
        console.log("setupUpgrade: Creating ChainUpgrade_v31");
        chainUpgrade = new ChainUpgrade_v31();

        console.log("Preparing ecosystem upgrade");
        ecosystemUpgrade.prepareEcosystemUpgrade();

        console.log("Preparing chain for the upgrade");
        chainUpgrade.prepareChainWithBridgehub(chainId, bridgehubProxy);
        console.log("setupUpgrade: Complete");
    }

    /// @notice Override this in child classes to use mocked versions
    function createEcosystemUpgrade() internal virtual returns (EcosystemUpgrade_v31) {
        return new EcosystemUpgrade_v31();
    }

    /// @notice Override this in child classes to use mocked versions (deprecated - use createEcosystemUpgrade instead)
    function createCTMUpgrade() internal virtual returns (CTMUpgrade_v31) {
        return new CTMUpgrade_v31();
    }

    /// @notice Hook for test-specific setup before chain upgrade
    /// @dev Override in child classes to set up storage or other test-specific state
    function beforeChainUpgrade() internal virtual {}

    function internalTest() internal virtual {
        console.log("internalTest: Starting");
        vm.recordLogs();
        console.log("internalTest: Getting CTM upgrade from ecosystem upgrade");
        ctmUpgrade = CTMUpgrade_v31(address(ecosystemUpgrade.getCTMUpgrade()));
        console.log("internalTest: Preparing combined ecosystem governance calls (includes CTM)");
        (
            Call[] memory upgradeStage0Calls,
            Call[] memory upgradeStage1Calls,
            Call[] memory upgradeStage2Calls
        ) = ecosystemUpgrade.prepareDefaultGovernanceCalls();

        // Note: ecosystemUpgrade.prepareDefaultGovernanceCalls() already combines both
        // core and CTM governance calls, so we don't need to call ctmUpgrade separately

        console.log("Starting upgrade stage 0 (combined ecosystem + CTM)!");
        governanceMulticall(ecosystemUpgrade.getOwnerAddress(), upgradeStage0Calls);

        console.log("Starting upgrade stage 1 (combined ecosystem + CTM)!");
        governanceMulticall(ecosystemUpgrade.getOwnerAddress(), upgradeStage1Calls);

        console.log("Starting upgrade stage 2 (combined ecosystem + CTM)!");
        governanceMulticall(ecosystemUpgrade.getOwnerAddress(), upgradeStage2Calls);

        console.log("Ecosystem upgrade is prepared, now all the chains have to upgrade to the new version");

        console.log("Upgrading gateway");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        Diamond.DiamondCutData memory diamondCutData = GetDiamondCutData.getDiamondCutDataFromRecordedLogs(
            logs,
            ctmUpgrade.getCTMAddress()
        );

        // Hook for test-specific setup before chain upgrade
        beforeChainUpgrade();

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
}
