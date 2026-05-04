// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {Vm} from "forge-std/Vm.sol";

import {Call} from "contracts/governance/Common.sol";
import {Test} from "forge-std/Test.sol";
import {CoreUpgrade_v31} from "../../../../deploy-scripts/upgrade/v31/CoreUpgrade_v31.s.sol";
import {CTMUpgrade_v31} from "../../../../deploy-scripts/upgrade/v31/CTMUpgrade_v31.s.sol";
import {EcosystemUpgradeParams} from "../../../../deploy-scripts/upgrade/default-upgrade/UpgradeParams.sol";
import {ChainUpgrade_v31} from "../../../../deploy-scripts/upgrade/v31/ChainUpgrade_v31.s.sol";
import {UpgradeUtils} from "../../../../deploy-scripts/upgrade/default-upgrade/UpgradeUtils.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {GetDiamondCutData} from "../../../../deploy-scripts/utils/GetDiamondCutData.sol";

contract UpgradeIntegrationTestBase is Test {
    using stdToml for string;

    uint256 chainId;

    CoreUpgrade_v31 coreUpgrade;
    CTMUpgrade_v31 ctmUpgrade;
    ChainUpgrade_v31 chainUpgrade;

    /// @notice Per-test fixed paths for the deploy outputs the upgrade scripts read.
    string public ECOSYSTEM_INPUT = "file_1.toml";
    string public ECOSYSTEM_UPGRADE_INPUT = "/upgrade-envs/v0.31.0-interopB/shared.toml";
    string public ECOSYSTEM_OUTPUT = "file_3.toml";
    string public CTM_INPUT = "/upgrade-envs/v0.31.0-interopB/shared.toml";
    string public CORE_OUTPUT = "/script-out/foundry-upgrade/upgrade-core.toml";
    string public CTM_OUTPUT = "/script-out/foundry-upgrade/mainnet-gateway.toml";
    string public CHAIN_INPUT;
    string public CHAIN_OUTPUT;

    function setupUpgrade(bool skipFactoryDepsCheck) public virtual {
        console.log("setupUpgrade: Creating CoreUpgrade_v31 and CTMUpgrade_v31");
        coreUpgrade = createCoreUpgrade();
        ctmUpgrade = createCTMUpgrade();

        console.log("setupUpgrade: Reading deployment outputs");
        string memory root = vm.projectRoot();
        vm.createDir(string.concat(root, "/script-out/foundry-upgrade"), true);
        string memory outputDeployL1Toml = vm.readFile(string.concat(root, ECOSYSTEM_INPUT));
        string memory outputDeployCTMToml = vm.readFile(string.concat(root, CTM_INPUT));

        EcosystemUpgradeParams memory params = _readEcosystemParams(outputDeployL1Toml, outputDeployCTMToml);

        console.log("setupUpgrade: Initializing core upgrade");
        coreUpgrade.initializeWithArgs(
            params.bridgehubProxyAddress,
            params.isZKsyncOS,
            params.create2FactorySalt,
            params.upgradeInputPath,
            CORE_OUTPUT
        );
        console.log("setupUpgrade: Initializing CTM upgrade");
        ctmUpgrade.initializeWithArgs(
            params.ctmProxy,
            params.bytecodesSupplier,
            params.isZKsyncOS,
            params.rollupDAManager,
            params.create2FactorySalt,
            params.upgradeInputPath,
            CTM_OUTPUT,
            params.governance,
            params.zkTokenAssetId
        );

        console.log("setupUpgrade: Deploying new ecosystem contracts");
        coreUpgrade.deployNewEcosystemContractsL1();

        console.log("setupUpgrade: Creating ChainUpgrade_v31");
        chainUpgrade = new ChainUpgrade_v31();

        // Hook for child classes to mutate Core/CTM state after init but before prepare
        // (e.g. local test needs to bump CTM's protocol version from the upgrade input).
        afterInitHook();

        console.log("setupUpgrade: Preparing core + CTM upgrades");
        coreUpgrade.prepareEcosystemUpgrade();
        ctmUpgrade.prepareCTMUpgrade();

        console.log("setupUpgrade: Preparing chain for the upgrade");
        chainUpgrade.prepareChainWithBridgehub(chainId, params.bridgehubProxyAddress);
        console.log("setupUpgrade: Complete");
    }

    /// @notice Override in child classes to use mocked versions.
    function createCoreUpgrade() internal virtual returns (CoreUpgrade_v31) {
        return new CoreUpgrade_v31();
    }

    /// @notice Override in child classes to use mocked versions.
    function createCTMUpgrade() internal virtual returns (CTMUpgrade_v31) {
        return new CTMUpgrade_v31();
    }

    /// @notice Hook for test-specific setup before chain upgrade.
    function beforeChainUpgrade() internal virtual {}

    /// @notice Hook called after Core and CTM are initialized + core deploy ran, but before
    ///         their prepare steps. Subclasses use this to override values that would
    ///         otherwise need to be read by the prepare pipelines (e.g. protocol version).
    function afterInitHook() internal virtual {}

    function internalTest() internal virtual {
        console.log("internalTest: Starting");
        vm.recordLogs();

        console.log("internalTest: Preparing core + CTM governance calls and merging by stage");
        (
            Call[] memory upgradeStage0Calls,
            Call[] memory upgradeStage1Calls,
            Call[] memory upgradeStage2Calls
        ) = _mergeCoreAndCTMGovernanceCalls();

        console.log("Starting upgrade stage 0 (core + CTM merged)!");
        governanceMulticall(coreUpgrade.getOwnerAddress(), upgradeStage0Calls);

        console.log("Starting upgrade stage 1 (core + CTM merged)!");
        governanceMulticall(coreUpgrade.getOwnerAddress(), upgradeStage1Calls);

        console.log("Starting upgrade stage 2 (core + CTM merged)!");
        governanceMulticall(coreUpgrade.getOwnerAddress(), upgradeStage2Calls);

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
    }

    /// @dev Merges per-stage governance calls from core and CTM. Inlines the orchestration that
    ///      `DefaultEcosystemUpgrade.prepareDefaultGovernanceCalls` used to do; no merged TOML is
    ///      written because production callers now pass the per-script TOMLs to
    ///      `protocol-ops upgrade-governance` separately.
    function _mergeCoreAndCTMGovernanceCalls()
        internal
        returns (Call[] memory stage0, Call[] memory stage1, Call[] memory stage2)
    {
        (Call[] memory coreStage0, Call[] memory coreStage1, Call[] memory coreStage2) = coreUpgrade
            .prepareDefaultGovernanceCalls();
        (Call[] memory ctmStage0, Call[] memory ctmStage1, Call[] memory ctmStage2) = ctmUpgrade
            .prepareDefaultGovernanceCalls();

        Call[][] memory s0 = new Call[][](2);
        s0[0] = coreStage0;
        s0[1] = ctmStage0;
        stage0 = UpgradeUtils.mergeCallsArray(s0);

        Call[][] memory s1 = new Call[][](2);
        s1[0] = coreStage1;
        s1[1] = ctmStage1;
        stage1 = UpgradeUtils.mergeCallsArray(s1);

        Call[][] memory s2 = new Call[][](2);
        s2[0] = coreStage2;
        s2[1] = ctmStage2;
        stage2 = UpgradeUtils.mergeCallsArray(s2);
    }

    function _readEcosystemParams(
        string memory outputDeployL1Toml,
        string memory outputDeployCTMToml
    ) private view returns (EcosystemUpgradeParams memory) {
        address bridgehubProxy = outputDeployL1Toml.readAddress("$.deployed_addresses.bridgehub.bridgehub_proxy_addr");
        address ctmProxy = outputDeployCTMToml.readAddress(
            "$.deployed_addresses.state_transition.state_transition_proxy_addr"
        );
        address bytecodesSupplier = outputDeployCTMToml.readAddress(
            "$.deployed_addresses.state_transition.bytecodes_supplier_addr"
        );
        bool isZKsyncOs = outputDeployCTMToml.readBool("$.is_zk_sync_os");
        address rollupDAManager = isZKsyncOs
            ? outputDeployCTMToml.readAddress("$.deployed_addresses.blobs_zksync_os_l1_da_validator_addr")
            : outputDeployCTMToml.readAddress("$.deployed_addresses.l1_rollup_da_manager");
        address governance = outputDeployL1Toml.readAddress("$.deployed_addresses.governance_addr");

        return
            EcosystemUpgradeParams({
                bridgehubProxyAddress: bridgehubProxy,
                ctmProxy: ctmProxy,
                bytecodesSupplier: bytecodesSupplier,
                rollupDAManager: rollupDAManager,
                isZKsyncOS: isZKsyncOs,
                create2FactorySalt: bytes32(0),
                upgradeInputPath: ECOSYSTEM_UPGRADE_INPUT,
                ecosystemOutputPath: ECOSYSTEM_OUTPUT,
                governance: governance,
                // Dummy asset ID is fine for these tests — fixed-ZK-fee bundles are not exercised.
                zkTokenAssetId: bytes32(uint256(1))
            });
    }

    /// @dev This is a contract that is used for additional visibility of transactions
    /// that the decentralized governance should do.
    function governanceMulticall(address governanceAddr, Call[] memory calls) internal {
        vm.startBroadcast(governanceAddr);

        for (uint256 i = 0; i < calls.length; i++) {
            Call memory call = calls[i];
            (bool success, ) = payable(call.target).call{value: call.value}(call.data);
            require(success, "Multicall failed");
        }

        vm.stopBroadcast();
    }
}
