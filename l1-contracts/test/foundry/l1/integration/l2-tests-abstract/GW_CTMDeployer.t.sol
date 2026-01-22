// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {Test} from "forge-std/Test.sol";

import {Facets, GatewayCTMDeployerConfig, GatewayDADeployerConfig, GatewayProxyAdminDeployerConfig, GatewayValidatorTimelockDeployerConfig, GatewayVerifiersDeployerConfig, GatewayCTMFinalConfig, DAContracts, GatewayProxyAdminDeployerResult, GatewayValidatorTimelockDeployerResult, Verifiers} from "contracts/state-transition/chain-deps/gateway-ctm-deployer/GatewayCTMDeployer.sol";
import {GatewayCTMDeployerDA} from "contracts/state-transition/chain-deps/gateway-ctm-deployer/GatewayCTMDeployerDA.sol";
import {GatewayCTMDeployerProxyAdmin} from "contracts/state-transition/chain-deps/gateway-ctm-deployer/GatewayCTMDeployerProxyAdmin.sol";
import {GatewayCTMDeployerValidatorTimelock} from "contracts/state-transition/chain-deps/gateway-ctm-deployer/GatewayCTMDeployerValidatorTimelock.sol";
import {GatewayCTMDeployerVerifiers} from "contracts/state-transition/chain-deps/gateway-ctm-deployer/GatewayCTMDeployerVerifiers.sol";
import {GatewayCTMDeployerCTM} from "contracts/state-transition/chain-deps/gateway-ctm-deployer/GatewayCTMDeployerCTM.sol";

abstract contract GW_CTMDeployerTest is Test {
    function test_GW_CTMDeployer() public {
        GatewayCTMDeployerConfig memory deployerConfig = GatewayCTMDeployerConfig({
            aliasedGovernanceAddress: makeAddr("aliasedGovernanceAddress"),
            salt: keccak256("test-salt"),
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
        });

        // Deploy phases 1-3
        (
            DAContracts memory daResult,
            GatewayProxyAdminDeployerResult memory proxyAdminResult,
            GatewayValidatorTimelockDeployerResult memory vtResult
        ) = _deployPhases1to3(deployerConfig);

        // Deploy phases 4-5
        _deployPhases4to5(deployerConfig, proxyAdminResult, vtResult);
    }

    function _deployPhases1to3(
        GatewayCTMDeployerConfig memory deployerConfig
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
            salt: deployerConfig.salt,
            aliasedGovernanceAddress: deployerConfig.aliasedGovernanceAddress
        });
        daResult = (new GatewayCTMDeployerDA(daConfig)).getResult();

        // Phase 2: ProxyAdmin deployer
        GatewayProxyAdminDeployerConfig memory proxyAdminConfig = GatewayProxyAdminDeployerConfig({
            salt: deployerConfig.salt,
            aliasedGovernanceAddress: deployerConfig.aliasedGovernanceAddress
        });
        proxyAdminResult = (new GatewayCTMDeployerProxyAdmin(proxyAdminConfig)).getResult();

        // Phase 3: ValidatorTimelock deployer
        GatewayValidatorTimelockDeployerConfig memory vtConfig = GatewayValidatorTimelockDeployerConfig({
            salt: deployerConfig.salt,
            aliasedGovernanceAddress: deployerConfig.aliasedGovernanceAddress,
            chainTypeManagerProxyAdmin: proxyAdminResult.chainTypeManagerProxyAdmin
        });
        vtResult = (new GatewayCTMDeployerValidatorTimelock(vtConfig)).getResult();
    }

    function _deployPhases4to5(
        GatewayCTMDeployerConfig memory deployerConfig,
        GatewayProxyAdminDeployerResult memory proxyAdminResult,
        GatewayValidatorTimelockDeployerResult memory vtResult
    ) internal {
        // Phase 4: Verifiers deployer
        GatewayVerifiersDeployerConfig memory verifiersConfig = GatewayVerifiersDeployerConfig({
            salt: deployerConfig.salt,
            aliasedGovernanceAddress: deployerConfig.aliasedGovernanceAddress,
            testnetVerifier: deployerConfig.testnetVerifier,
            isZKsyncOS: deployerConfig.isZKsyncOS
        });
        Verifiers memory verifiersResult = (new GatewayCTMDeployerVerifiers(verifiersConfig)).getResult();

        // Phase 5: CTM deployer
        // Note: Direct deployments (AdminFacet, MailboxFacet, ExecutorFacet, GettersFacet,
        // DiamondInit, GenesisUpgrade) would be done separately in scripts.
        // For this test, we use placeholder addresses.
        _deployPhase5(deployerConfig, proxyAdminResult, vtResult, verifiersResult);
    }

    function _deployPhase5(
        GatewayCTMDeployerConfig memory deployerConfig,
        GatewayProxyAdminDeployerResult memory proxyAdminResult,
        GatewayValidatorTimelockDeployerResult memory vtResult,
        Verifiers memory verifiersResult
    ) internal {
        GatewayCTMFinalConfig memory ctmConfig = GatewayCTMFinalConfig({
            baseConfig: deployerConfig,
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
