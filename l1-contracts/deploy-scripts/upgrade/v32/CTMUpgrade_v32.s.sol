// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {Utils} from "../../utils/Utils.sol";

import {Call} from "contracts/governance/Common.sol";

import {DefaultCTMUpgrade} from "../default-upgrade/DefaultCTMUpgrade.s.sol";
import {CTMUpgradeParams} from "../default-upgrade/UpgradeParams.sol";
import {CTMContract, DeployCTML1OrGateway} from "../../ctm/DeployCTML1OrGateway.sol";

/// @notice Script used for the v32 (atomic interop) upgrade flow, upgrading from v31.
/// @dev v32 is storage-compatible but NOT function-preserving: in-flight flows (e.g. withdrawals)
///      may break across the upgrade. Consequences for this script compared to v31:
///      - no version-specific L1 upgrade contract — the plain `DefaultUpgrade` is used;
///      - no L2 delegate (`L2V31Upgrade`-style migration contract) — the L2 side of the upgrade
///        only force-deploys the new (atomic-interop) L2 bytecode set;
///      - no new proxies — every proxy already exists on the v31 baseline and is discovered by
///        `AddressIntrospector`; only implementations are deployed (via CREATE2, so unchanged
///        contracts land on their existing implementation address and the swap is a no-op).
/// @dev v32 is intended to be the first registry-driven upgrade: the addresses this script
///      deploys are the manifest input of `scripts/gen-registry.ts`, and governance execution
///      goes through `UpgradeExecutor` + `CTMUpgradeModule` (see
///      contracts/upgrades/registry/) once protocol-ops adopts that flow. Until then this script
///      also serializes the classic stage calls.
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
        // v32 needs no version-specific L1 upgrade logic — the base deploys `DefaultUpgrade`.
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

    /// @notice From v32 onwards both VMs use the universal ComplexUpgrader path. v32 has no L2
    ///         delegate: the upgrade transaction only force-deploys the new L2 bytecode set
    ///         (storage-compatible, no L2 state migration).
    function getEraL2UpgradeTargetAndData(
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory _deployments
    ) internal virtual override returns (address, bytes memory) {
        return getComplexUpgraderTargetAndData(_deployments, address(0), "");
    }

    // ZKsyncOS keeps the base behavior (universal path, no delegate).
}
