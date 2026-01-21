// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {StdStorage, Test, stdStorage, console} from "forge-std/Test.sol";

import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";
import {GW_ASSET_TRACKER, GW_ASSET_TRACKER_ADDR, L2_CHAIN_ASSET_HANDLER, L2_BOOTLOADER_ADDRESS, L2_BRIDGEHUB, L2_MESSAGE_ROOT, L2_MESSAGE_ROOT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {ProcessLogsInput} from "contracts/state-transition/chain-interfaces/IExecutor.sol";

import {L2AssetTrackerData} from "./L2AssetTrackerData.sol";

import {Facets, GatewayCTMDeployerConfig, GatewayDADeployerConfig, GatewayProxyAdminDeployerConfig, GatewayValidatorTimelockDeployerConfig, GatewayVerifiersDeployerConfig, GatewayCTMFinalConfig, DAContracts, GatewayProxyAdminDeployerResult, GatewayValidatorTimelockDeployerResult, Verifiers} from "contracts/state-transition/chain-deps/gateway-ctm-deployer/GatewayCTMDeployer.sol";
import {GatewayCTMDeployerDA} from "contracts/state-transition/chain-deps/gateway-ctm-deployer/GatewayCTMDeployerDA.sol";
import {GatewayCTMDeployerProxyAdmin} from "contracts/state-transition/chain-deps/gateway-ctm-deployer/GatewayCTMDeployerProxyAdmin.sol";
import {GatewayCTMDeployerValidatorTimelock} from "contracts/state-transition/chain-deps/gateway-ctm-deployer/GatewayCTMDeployerValidatorTimelock.sol";
import {GatewayCTMDeployerVerifiers} from "contracts/state-transition/chain-deps/gateway-ctm-deployer/GatewayCTMDeployerVerifiers.sol";
import {GatewayCTMDeployerCTM} from "contracts/state-transition/chain-deps/gateway-ctm-deployer/GatewayCTMDeployerCTM.sol";

abstract contract GW_CTMDeployerTest is Test {
    using stdStorage for StdStorage;

    bytes32 internal constant TEST_SALT = keccak256("test-salt");

    function test_GW_CTMDeployer() public {
        address aliasedGovernanceAddress = makeAddr("aliasedGovernanceAddress");

        // Deploy phases 1-3
        (
            DAContracts memory daResult,
            GatewayProxyAdminDeployerResult memory proxyAdminResult,
            GatewayValidatorTimelockDeployerResult memory vtResult
        ) = _deployPhases1to3(aliasedGovernanceAddress);

        // Deploy phases 4-5
        _deployPhases4to5(aliasedGovernanceAddress, proxyAdminResult, vtResult);
    }

    function _deployPhases1to3(
        address aliasedGovernanceAddress
    )
        internal
        returns (
            DAContracts memory daResult,
            GatewayProxyAdminDeployerResult memory proxyAdminResult,
            GatewayValidatorTimelockDeployerResult memory vtResult
        )
    {
        // Phase 1: DA deployer
        GatewayDADeployerConfig memory daConfig = GatewayDADeployerConfig({
            salt: TEST_SALT,
            aliasedGovernanceAddress: aliasedGovernanceAddress
        });
        daResult = (new GatewayCTMDeployerDA(daConfig)).getResult();

        // Phase 2: ProxyAdmin deployer
        GatewayProxyAdminDeployerConfig memory proxyAdminConfig = GatewayProxyAdminDeployerConfig({
            salt: TEST_SALT,
            aliasedGovernanceAddress: aliasedGovernanceAddress
        });
        proxyAdminResult = (new GatewayCTMDeployerProxyAdmin(proxyAdminConfig)).getResult();

        // Phase 3: ValidatorTimelock deployer
        GatewayValidatorTimelockDeployerConfig memory vtConfig = GatewayValidatorTimelockDeployerConfig({
            salt: TEST_SALT,
            aliasedGovernanceAddress: aliasedGovernanceAddress,
            chainTypeManagerProxyAdmin: proxyAdminResult.chainTypeManagerProxyAdmin
        });
        vtResult = (new GatewayCTMDeployerValidatorTimelock(vtConfig)).getResult();
    }

    function _deployPhases4to5(
        address aliasedGovernanceAddress,
        GatewayProxyAdminDeployerResult memory proxyAdminResult,
        GatewayValidatorTimelockDeployerResult memory vtResult
    ) internal {
        // Phase 4: Verifiers deployer
        GatewayVerifiersDeployerConfig memory verifiersConfig = GatewayVerifiersDeployerConfig({
            salt: TEST_SALT,
            aliasedGovernanceAddress: aliasedGovernanceAddress,
            testnetVerifier: false,
            isZKsyncOS: false
        });
        Verifiers memory verifiersResult = (new GatewayCTMDeployerVerifiers(verifiersConfig))
            .getResult();

        // Phase 5: CTM deployer
        // Note: Direct deployments (AdminFacet, MailboxFacet, ExecutorFacet, GettersFacet,
        // DiamondInit, GenesisUpgrade) would be done separately in scripts.
        // For this test, we use placeholder addresses.
        _deployPhase5(aliasedGovernanceAddress, proxyAdminResult, vtResult, verifiersResult);
    }

    function _deployPhase5(
        address aliasedGovernanceAddress,
        GatewayProxyAdminDeployerResult memory proxyAdminResult,
        GatewayValidatorTimelockDeployerResult memory vtResult,
        Verifiers memory verifiersResult
    ) internal {
        GatewayCTMFinalConfig memory ctmConfig = GatewayCTMFinalConfig({
            baseConfig: GatewayCTMDeployerConfig({
                aliasedGovernanceAddress: aliasedGovernanceAddress,
                salt: TEST_SALT,
                eraChainId: 1,
                l1ChainId: 1,
                testnetVerifier: false,
                isZKsyncOS: false,
                adminSelectors: new bytes4[](0),
                executorSelectors: new bytes4[](0),
                mailboxSelectors: new bytes4[](0),
                gettersSelectors: new bytes4[](0),
                bootloaderHash: keccak256("bootloader-hash"),
                defaultAccountHash: keccak256("default-account-hash"),
                evmEmulatorHash: keccak256("evm-emulator-hash"),
                genesisRoot: keccak256("genesis-root"),
                genesisRollupLeafIndex: 1,
                genesisBatchCommitment: keccak256("genesis-batch-commitment"),
                forceDeploymentsData: bytes(""),
                protocolVersion: 0
            }),
            chainTypeManagerProxyAdmin: proxyAdminResult.chainTypeManagerProxyAdmin,
            validatorTimelockProxy: vtResult.validatorTimelockProxy,
            // Placeholder addresses for direct deployments
            facets: Facets({
                adminFacet: address(0x1),
                mailboxFacet: address(0x3),
                executorFacet: address(0x4),
                gettersFacet: address(0x2),
                diamondInit: address(0x5)
            }),
            genesisUpgrade: address(0x6),
            verifier: verifiersResult.verifier
        });
        new GatewayCTMDeployerCTM(ctmConfig);
    }
}
