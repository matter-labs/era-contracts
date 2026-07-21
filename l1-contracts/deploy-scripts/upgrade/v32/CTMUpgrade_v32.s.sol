// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {L2_GENESIS_UPGRADE_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {IL2GenesisUpgrade} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {Utils} from "../../utils/Utils.sol";

import {Call} from "contracts/governance/Common.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";

import {DefaultCTMUpgrade} from "../default-upgrade/DefaultCTMUpgrade.s.sol";
import {CTMUpgradeParams} from "../default-upgrade/UpgradeParams.sol";
import {CTMContract, DeployCTML1OrGateway} from "../../ctm/DeployCTML1OrGateway.sol";

/// @notice Script used for the v32 (atomic interop) upgrade flow, upgrading from v31.
/// @dev v32 is storage-compatible but NOT function-preserving: in-flight flows (e.g. withdrawals)
///      may break across the upgrade. Consequences for this script compared to v31:
///      - the version upgrade contract (`SettlementLayerV32Upgrade`) performs NO L1 storage
///        migration — it only injects per-chain arguments into the L2 upgrade transaction;
///      - no `L2V31Upgrade`-style migration contract on L2 — the upgrade delegates to the
///        `L2GenesisUpgrade` built-in, the same contract that initializes the L2 system-contract
///        set at chain genesis, which (re)initializes the contracts introduced by v32;
///      - no new proxies — every proxy already exists on the v31 baseline and is discovered by
///        `AddressIntrospector`; only implementations are deployed (via CREATE2, so unchanged
///        contracts land on their existing implementation address and the swap is a no-op).
/// @dev v32 EXECUTES through the legacy stage-calldata pipeline; what is registry-driven about
///      it is GENESIS (this script deploys + pins the genesis `CTMRelease`, so every v33+
///      transition has a real `fromRelease`). Production adoption of the on-chain execution
///      path — deploying the canonical factories + bound executors and handing the CTM and the
///      ecosystem ProxyAdmin over to them — is deliberately NOT part of this script: it is the
///      v33 protocol-ops preparation work, tracked there. Today that wiring exists only in the
///      test harnesses (foundry e2e + anvil runner).
contract CTMUpgrade_v32 is Script, DefaultCTMUpgrade {
    /// @notice Single-call entry point invoked by the protocol-ops CLI's `ecosystem upgrade-prepare-all`.
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

        // Emit test-only calls (`test_create_chain`, `test_upgrade_chain`) into the CTM output
        // TOML so protocol-ops can lift them into merged `ecosystem.toml` for tx-simulator checks.
        prepareDefaultTestUpgradeCalls();
    }

    /// @notice Deploy the v32 CTM-side implementation set. Implementations only: existing
    ///         proxies are discovered from the live CTM, and unchanged contracts re-deploy to
    ///         their existing CREATE2 address.
    function deployNewCTMContracts() public virtual override {
        ctmAddresses.stateTransition.defaultUpgrade = deployUsedUpgradeContract();
        ctmAddresses.stateTransition.genesisUpgrade = deploySimpleContract("L1GenesisUpgrade", false);

        deployVerifiers();

        deployEIP7702Checker();
        deployUpgradeStageValidator();
        deployGovernanceUpgradeTimer();

        // New ChainTypeManager implementation (per VM: Era vs ZKsyncOS).
        (, string memory ctmContractName) = DeployCTML1OrGateway.resolve(
            config.isZKsyncOS,
            CTMContract.ChainTypeManager
        );
        console.log("Deploying ChainTypeManager:", ctmContractName);
        ctmAddresses.stateTransition.implementations.chainTypeManager = deploySimpleContract(ctmContractName, false);

        ctmAddresses.stateTransition.implementations.serverNotifier = deploySimpleContract("ServerNotifier", false);

        // MultisigCommitter is the default validator-timelock implementation since v31; if its
        // bytecode is unchanged this lands on the live implementation address and the stage-1
        // swap below is skipped.
        ctmAddresses.stateTransition.implementations.validatorTimelock = deploySimpleContract(
            "MultisigCommitter",
            false
        );

        // v32 is the first registry-driven genesis: `deployStateTransitionDiamondFacets` deploys
        // the genesis `CTMRelease` (the upgraded CTM is pinned to it via `setCurrentRelease` in
        // the stage-1 bundle), and the registry manifest embeds the fixed force-deployments data.
        // That data is artifact-derived (bytecode hashes + core addresses), so it can — and must —
        // be generated here, before the registry deploy, rather than in the later
        // `generateUpgradeData` step. The result is cached, so the later call is a no-op.
        getFixedForceDeploymentsData();

        // Deploys the v32 facet set and the genesis `CTMRegistry` (see above). The genesis-upgrade
        // address and facet set it pins were deployed just above.
        deployStateTransitionDiamondFacets();
    }

    /// @notice Append the ValidatorTimelock proxy swap to the stage-1 bundle — only if the v32
    ///         implementation actually differs from the one the proxy currently points at.
    function prepareVersionSpecificStage1GovernanceCallsL1() public virtual override returns (Call[] memory calls) {
        address validatorTimelockProxy = ctmAddresses.stateTransition.proxies.validatorTimelock;
        address newImpl = ctmAddresses.stateTransition.implementations.validatorTimelock;
        require(validatorTimelockProxy != address(0), "v32: validatorTimelock proxy not set");
        require(newImpl != address(0), "v32: validatorTimelock impl not deployed");

        // EIP-1967 implementation slot.
        address currentImpl = address(
            uint160(
                uint256(
                    vm.load(validatorTimelockProxy, 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc)
                )
            )
        );
        if (currentImpl == newImpl) {
            // Unchanged bytecode re-deployed to the same CREATE2 address: nothing to swap.
            return new Call[](0);
        }

        calls = new Call[](1);
        calls[0] = Call({
            target: Utils.getProxyAdminAddress(validatorTimelockProxy),
            data: abi.encodeCall(
                ProxyAdmin.upgrade,
                (ITransparentUpgradeableProxy(payable(validatorTimelockProxy)), newImpl)
            ),
            value: 0
        });
    }

    /// @notice v32 governance call: pin the (freshly deployed) genesis `CTMRegistry` on the
    ///         upgraded CTM. This replaces the legacy `setChainCreationParams` emission from
    ///         `DefaultCTMUpgrade` — the v32 CTM reads all genesis data from the registry instead.
    /// @dev `setCurrentRelease` validates `genesisParams` at the CTM's CURRENT protocol version,
    ///      which only becomes the new (v32) version once `setNewVersionUpgrade` runs. So this
    ///      stage-1 slot emits nothing; the `setCurrentRelease` call is appended right AFTER the
    ///      version bump in `provideSetNewVersionUpgradeCall` below.
    function prepareNewChainCreationParamsCall() public virtual override returns (Call[] memory calls) {
        return new Call[](0);
    }

    /// @notice Emit `setNewVersionUpgrade` (bumps the CTM to v32) immediately followed by
    ///         `setReleaseFactory` (migrated CTM storage predates the field, and release
    ///         provenance cannot be checked against a zero factory) and `setCurrentRelease`
    ///         (pins the v32 genesis release, whose `genesisParams` the CTM now validates at
    ///         the just-set v32 version).
    function provideSetNewVersionUpgradeCall() public virtual override returns (Call[] memory calls) {
        Call[] memory setVersionCalls = super.provideSetNewVersionUpgradeCall();

        address ctm = ctmAddresses.stateTransition.proxies.chainTypeManager;
        address release = ctmAddresses.stateTransition.currentRelease;
        address releaseFactory = ctmAddresses.stateTransition.releaseFactory;
        require(ctm != address(0), "v32: chainTypeManager proxy is zero");
        require(release != address(0), "v32: current release not deployed");
        require(releaseFactory != address(0), "v32: release factory not deployed");

        calls = new Call[](setVersionCalls.length + 2);
        for (uint256 i = 0; i < setVersionCalls.length; ++i) {
            calls[i] = setVersionCalls[i];
        }
        calls[setVersionCalls.length] = Call({
            target: ctm,
            data: abi.encodeCall(IChainTypeManager.setReleaseFactory, (releaseFactory)),
            value: 0
        });
        calls[setVersionCalls.length + 1] = Call({
            target: ctm,
            data: abi.encodeCall(IChainTypeManager.setCurrentRelease, (release)),
            value: 0
        });
    }

    /// @notice Deploy the v32 upgrade contract: one contract serves both VMs (both use the
    ///         universal ComplexUpgrader path from v32 onwards).
    function deployUsedUpgradeContract() internal virtual override returns (address) {
        console.log("Deploying SettlementLayerV32Upgrade");
        return deploySimpleContract("SettlementLayerV32Upgrade", false);
    }

    /// @notice The committed (ecosystem-wide) L2 genesis-upgrade calldata. The chainId and
    ///         additionalForceDeploymentsData are placeholders rewritten per chain by
    ///         `SettlementLayerV32Upgrade.getL2UpgradeTxData` at upgrade time.
    function getV32L2UpgradeCalldata() internal view returns (bytes memory) {
        return
            abi.encodeCall(
                IL2GenesisUpgrade.genesisUpgrade,
                (
                    config.isZKsyncOS,
                    0,
                    coreAddresses.bridgehub.proxies.ctmDeploymentTracker,
                    generatedData.forceDeploymentsData,
                    ""
                )
            );
    }

    /// @notice From v32 onwards both VMs use the universal ComplexUpgrader path, delegating to
    ///         the `L2GenesisUpgrade` built-in for L2-side initialization.
    function getEraL2UpgradeTargetAndData(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _deployments
    ) internal virtual override returns (address, bytes memory) {
        return
            getUniversalComplexUpgraderTargetAndData(_deployments, L2_GENESIS_UPGRADE_ADDR, getV32L2UpgradeCalldata());
    }

    function getZKsyncOSL2UpgradeTargetAndData(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _deployments
    ) internal virtual override returns (address, bytes memory) {
        return
            getUniversalComplexUpgraderTargetAndData(_deployments, L2_GENESIS_UPGRADE_ADDR, getV32L2UpgradeCalldata());
    }
}
