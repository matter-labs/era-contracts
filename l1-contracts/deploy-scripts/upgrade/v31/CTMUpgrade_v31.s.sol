// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {L2_VERSION_SPECIFIC_UPGRADER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {Utils} from "../../utils/Utils.sol";
import {L2GenesisForceDeploymentsHelper} from "contracts/l2-upgrades/L2GenesisForceDeploymentsHelper.sol";

import {IL2V31Upgrade} from "contracts/upgrades/IL2V31Upgrade.sol";

import {Call} from "contracts/governance/Common.sol";

import {DefaultCTMUpgrade} from "../default-upgrade/DefaultCTMUpgrade.s.sol";
import {CTMUpgradeParams} from "../default-upgrade/UpgradeParams.sol";
import {CoreContract} from "../../ecosystem/CoreContract.sol";
import {CTMContract, DeployCTML1OrGateway} from "../../ctm/DeployCTML1OrGateway.sol";
import {IRollupDAManager} from "../../interfaces/IRollupDAManager.sol";

/// @notice Script used for v31 upgrade flow
contract CTMUpgrade_v31 is Script, DefaultCTMUpgrade {
    /// @notice Single-call entry point invoked by the protocol-ops CLI's `ecosystem upgrade-prepare-all`.
    ///         Mirrors `CoreUpgrade_v31.noGovernancePrepare`: drives the full CTM-side prepare phase
    ///         (deploy + bytecode publish + upgrade-cut generation + governance/admin call serialization)
    ///         in one shot so the caller doesn't need to chain `initializeWithArgs` → `prepareCTMUpgrade`
    ///         → call-serialization helpers over forge-script invocations.
    function noGovernancePrepare(CTMUpgradeParams memory _params) public {
        initializeWithArgs(
            _params.ctmProxy,
            _params.bytecodesSupplier,
            _params.isZKsyncOS,
            _params.rollupDAManager,
            _params.create2FactorySalt,
            _params.upgradeInputPath,
            _params.outputPath,
            _params.governance,
            _params.zkTokenAssetId
        );
        if (_params.chainRegistrationSender != address(0)) {
            coreAddresses.bridgehub.proxies.chainRegistrationSender = _params.chainRegistrationSender;
        }
        prepareCTMUpgrade();
        prepareDefaultGovernanceCalls();
        prepareDefaultCTMAdminCalls();

        // Emit test-only calls (`test_create_chain`, `test_upgrade_chain`) into
        // the CTM output TOML so protocol-ops can lift them into merged
        // `ecosystem.toml` for tx-simulator checks.
        prepareDefaultTestUpgradeCalls();
    }

    /// @notice Deploy everything that should be deployed
    function deployNewCTMContracts() public virtual override {
        // v31 Era-specific DA setup: the Era CTM does NOT reuse its pre-v31
        // RollupDAManager (whose legacy `(address,address)` DA-pair API is
        // incompatible with the v31 AdminFacet). Instead we deploy a fresh
        // RollupDAManager + RollupL1DAValidator and register the rollup DA pair,
        // mirroring the canonical CTM deployment flow (`DeployCTM.deployDAValidators`).
        // This must run before `deployStateTransitionDiamondFacets()` because the
        // AdminFacet bakes in the RollupDAManager address as an immutable.
        // ZKsync OS reuses its existing (v30) RollupDAManager and validator, so
        // we leave its DA addresses untouched.
        if (!config.isZKsyncOS) {
            deployEraRollupDA();
        }

        (ctmAddresses.stateTransition.defaultUpgrade) = deployUsedUpgradeContract();
        (ctmAddresses.stateTransition.genesisUpgrade) = deploySimpleContract("L1GenesisUpgrade", false);

        deployVerifiers();

        deployEIP7702Checker();
        deployUpgradeStageValidator();
        deployGovernanceUpgradeTimer();

        // Deploy BytecodesSupplier as TUPP (was a simple contract in old version)
        // This creates both implementation and proxy
        (
            ctmAddresses.stateTransition.implementations.bytecodesSupplier,
            ctmAddresses.stateTransition.proxies.bytecodesSupplier
        ) = deployTuppWithContract("BytecodesSupplier", false);

        (
            ctmAddresses.stateTransition.implementations.permissionlessValidator,
            ctmAddresses.stateTransition.proxies.permissionlessValidator
        ) = deployTuppWithContract("PermissionlessValidator", false);

        // Deploy new ChainTypeManager implementation
        // The constructor will receive the new BytecodesSupplier and PermissionlessValidator proxy addresses.
        // Select the correct ChainTypeManager based on chain type (Era vs ZKsyncOS)
        // FIXME we never actually use deploySimpleContract or deploy TUPP with anything else than false. We need to clean this code.
        (, string memory ctmContractName) = DeployCTML1OrGateway.resolve(
            config.isZKsyncOS,
            CTMContract.ChainTypeManager
        );
        console.log("Deploying ChainTypeManager:", ctmContractName);
        ctmAddresses.stateTransition.implementations.chainTypeManager = deploySimpleContract(ctmContractName, false);

        // Deploy new ServerNotifier implementation
        ctmAddresses.stateTransition.implementations.serverNotifier = deploySimpleContract("ServerNotifier", false);

        // v31 adds `UPGRADER_ROLE` + `upgradeChainFromVersion()` (IChainUpgrader) to ValidatorTimelock;
        // existing chains' proxy still points at the v30 impl, so swap it under the same CREATE2 flow.
        // The validator implementation is chain-type specific:
        //  - Era uses plain `ValidatorTimelock`.
        //  - ZKsyncOS uses `MultisigCommitter` (a superset of ValidatorTimelock) so the upgrade does NOT
        //    downgrade ZKsyncOS proxies that already run a MultisigCommitter — deploying plain
        //    `ValidatorTimelock` there would silently drop multisig-commit support.
        string memory validatorTimelockContractName = config.isZKsyncOS ? "MultisigCommitter" : "ValidatorTimelock";
        console.log("Deploying validator timelock implementation:", validatorTimelockContractName);
        ctmAddresses.stateTransition.implementations.validatorTimelock = deploySimpleContract(
            validatorTimelockContractName,
            false
        );

        deployStateTransitionDiamondFacets();
    }

    /// @notice Append the ValidatorTimelock proxy-admin upgrade to the stage-1 governance bundle.
    /// @dev Plain `ProxyAdmin.upgrade` (not `upgradeAndCall`): the new `MultisigCommitter` impl is deployed
    ///      with no reinitializer call. Proxies already running a MultisigCommitter are at `_initialized=2`
    ///      with their multisig storage intact, so the swap just restores the multisig code; calling
    ///      `reinitializeV2()` again would revert "already initialized".
    function prepareVersionSpecificStage1GovernanceCallsL1() public virtual override returns (Call[] memory calls) {
        address validatorTimelockProxy = ctmAddresses.stateTransition.proxies.validatorTimelock;
        address newImpl = ctmAddresses.stateTransition.implementations.validatorTimelock;
        require(validatorTimelockProxy != address(0), "v31: validatorTimelock proxy not set");
        require(newImpl != address(0), "v31: validatorTimelock impl not deployed");

        address proxyAdminAddr = Utils.getProxyAdminAddress(validatorTimelockProxy);

        calls = new Call[](1);
        calls[0] = Call({
            target: proxyAdminAddr,
            data: abi.encodeCall(
                ProxyAdmin.upgrade,
                (ITransparentUpgradeableProxy(payable(validatorTimelockProxy)), newImpl)
            ),
            value: 0
        });
    }

    /// @notice Deploy a fresh RollupDAManager + RollupL1DAValidator for the Era CTM
    ///         and register the rollup DA pair on it.
    /// @dev Mirrors `DeployCTM.deployDAValidators` (minus the validium/avail/zksync-os
    ///      validators that an Era rollup CTM upgrade does not need). The manager is
    ///      deployed owned by the deployer, which registers the DA pair while it still
    ///      owns the manager; the protocol-ops prepare flow then transfers the manager
    ///      to governance (the deferred `acceptOwnership()` lands in stage 0). The
    ///      freshly deployed manager address is what the AdminFacet immutable and the
    ///      merged `ecosystem.toml` ([ctms.era].deployed_addresses.l1_rollup_da_manager)
    ///      use, overriding the pre-v31 permanent value.
    function deployEraRollupDA() internal virtual {
        address deployer = getDeployerAddress();

        console.log("Deploying fresh v31 RollupDAManager for Era CTM");
        ctmAddresses.daAddresses.daContracts.rollupDAManager = deployWithCreate2AndOwner(
            "RollupDAManager",
            deployer,
            false
        );
        updateRollupDAManager();

        console.log("Deploying fresh RollupL1DAValidator for Era CTM");
        ctmAddresses.daAddresses.daContracts.rollupSLDAValidator = deploySimpleContract("RollupL1DAValidator", false);

        vm.broadcast(deployer);
        IRollupDAManager(ctmAddresses.daAddresses.daContracts.rollupDAManager).updateDAPair(
            ctmAddresses.daAddresses.daContracts.rollupSLDAValidator,
            getRollupL2DACommitmentScheme(),
            true
        );

        console.log("Era RollupDAManager:", ctmAddresses.daAddresses.daContracts.rollupDAManager);
        console.log("Era RollupL1DAValidator:", ctmAddresses.daAddresses.daContracts.rollupSLDAValidator);
    }

    /// @notice Record the freshly deployed Era rollup L1 DA validator in the CTM output.
    /// @dev `DefaultCTMUpgrade.saveOutput` writes the discovered chain's DA validator
    ///      (`discoveredEraZkChain.l1DAValidator`) by default. For the Era CTM we deploy
    ///      a new validator, so overwrite that field with the freshly deployed address.
    ///      For the ZKsync OS CTM we reuse the existing (v30) RollupDAManager + validator,
    ///      so the fresh-DA verification must be skipped. The default `saveOutput` records
    ///      the discovered *Era* chain's L1 DA validator here, which is non-zero whenever a
    ///      real Era chain is registered (e.g. mainnet chain 324) and would wrongly trigger
    ///      that verification. Write zero to signal "reuse" — matching the environments where
    ///      the Era chain is unregistered (testnet's legacy era 270) and the discovered
    ///      validator is already zero.
    function saveOutputVersionSpecific() internal virtual override {
        if (!config.isZKsyncOS && ctmAddresses.daAddresses.daContracts.rollupSLDAValidator != address(0)) {
            vm.writeToml(
                vm.toString(ctmAddresses.daAddresses.daContracts.rollupSLDAValidator),
                upgradeConfig.outputPath,
                ".deployed_addresses.rollup_l1_da_validator_addr"
            );
        } else if (config.isZKsyncOS) {
            vm.writeToml(
                vm.toString(address(0)),
                upgradeConfig.outputPath,
                ".deployed_addresses.rollup_l1_da_validator_addr"
            );
        }
    }

    /// @notice Override to deploy the correct v31 upgrade contract based on chain type.
    function deployUsedUpgradeContract() internal virtual override returns (address) {
        string memory contractName = config.isZKsyncOS
            ? "ZKsyncOSSettlementLayerV31Upgrade"
            : "EraSettlementLayerV31Upgrade";
        console.log("Deploying", contractName);
        return deploySimpleContract(contractName, false);
    }

    function getV31AdditionalFactoryDependencyContracts()
        internal
        pure
        returns (CoreContract[] memory additionalDependencyContracts)
    {
        additionalDependencyContracts = new CoreContract[](1);
        additionalDependencyContracts[0] = CoreContract.L2V31Upgrade;
    }

    function getAdditionalFactoryDependencyContracts()
        internal
        override
        returns (CoreContract[] memory additionalDependencyContracts)
    {
        return getV31AdditionalFactoryDependencyContracts();
    }

    function getAdditionalUniversalForceDeployments()
        internal
        override
        returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory additional)
    {
        if (config.isZKsyncOS) {
            return getV31AdditionalZKsyncOSUniversalForceDeployments();
        }

        return buildEraUniversalForceDeployments(getV31AdditionalFactoryDependencyContracts());
    }

    function getV31L2UpgradeCalldata() internal returns (bytes memory) {
        // The fixedForceDeploymentsData is ecosystem-wide (same for all chains).
        // The additionalForceDeploymentsData placeholder is rewritten per-chain by
        // SettlementLayerV31UpgradeBase._buildL2V31UpgradeCalldata at upgrade time.
        return
            abi.encodeCall(
                IL2V31Upgrade.upgrade,
                (
                    config.isZKsyncOS,
                    coreAddresses.bridgehub.proxies.ctmDeploymentTracker,
                    generatedData.forceDeploymentsData,
                    ""
                )
            );
    }

    function getEraL2UpgradeTargetAndData(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _deployments
    ) internal virtual override returns (address, bytes memory) {
        return
            getComplexUpgraderTargetAndData(_deployments, L2_VERSION_SPECIFIC_UPGRADER_ADDR, getV31L2UpgradeCalldata());
    }

    /// @notice V31-specific: include L2V31Upgrade as an additional ZKsyncOS force deployment.
    /// @dev L2V31Upgrade is deployed as a standalone contract at the derived random address used as
    /// the delegate target in `forceDeployAndUpgradeUniversal`, so it uses `ZKsyncOSUnsafeForceDeployment`
    /// rather than `ZKsyncOSSystemProxyUpgrade`.
    function getV31AdditionalZKsyncOSUniversalForceDeployments()
        internal
        returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory additional)
    {
        bytes memory bytecodeInfo = Utils.getZKOSBytecodeInfoForContract("L2V31Upgrade.sol", "L2V31Upgrade");
        additional = new IComplexUpgrader.UniversalContractUpgradeInfo[](1);
        additional[0] = IComplexUpgrader.UniversalContractUpgradeInfo({
            upgradeType: IComplexUpgrader.ContractUpgradeType.ZKsyncOSUnsafeForceDeployment,
            deployedBytecodeInfo: bytecodeInfo,
            newAddress: L2GenesisForceDeploymentsHelper.generateRandomAddress(bytecodeInfo)
        });
    }

    function getZKsyncOSL2UpgradeTargetAndData(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _deployments
    ) internal virtual override returns (address, bytes memory) {
        // For ZKsyncOS, the delegateTo address is a derived address (not the constant
        // L2_VERSION_SPECIFIC_UPGRADER_ADDR) to avoid overwriting existing bytecode.
        // Must match the newAddress in getV31AdditionalZKsyncOSUniversalForceDeployments.
        bytes memory bytecodeInfo = Utils.getZKOSBytecodeInfoForContract("L2V31Upgrade.sol", "L2V31Upgrade");
        address delegateTo = L2GenesisForceDeploymentsHelper.generateRandomAddress(bytecodeInfo);

        return getComplexUpgraderTargetAndData(_deployments, delegateTo, getV31L2UpgradeCalldata());
    }
}
