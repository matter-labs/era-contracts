// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {Call} from "contracts/governance/Common.sol";
import {IGovernance} from "contracts/governance/IGovernance.sol";
import {IChainAdmin} from "contracts/governance/IChainAdmin.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";
import {IChainAssetHandlerBase} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {FixedForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {IDefaultUpgrade} from "contracts/upgrades/IDefaultUpgrade.sol";

import {StateTransitionDeployedAddresses} from "../../utils/Types.sol";
import {Utils} from "../../utils/Utils.sol";
import {GetDiamondCutData} from "../../utils/GetDiamondCutData.sol";
import {CTMContract, DeployCTML1OrGateway} from "../../ctm/DeployCTML1OrGateway.sol";
import {DefaultCTMUpgrade} from "../default-upgrade/DefaultCTMUpgrade.s.sol";
import {UpgradeHelperLib} from "../default-upgrade/UpgradeHelperLib.sol";

/// @dev `Governance.minDelay()` is not part of {IGovernance}.
interface IGovernanceMinDelay {
    function minDelay() external view returns (uint256);
}

/// @notice Verifier-only upgrade of a ZKsync OS CTM on top of the default CTM upgrade flow
/// ({protocol-docs/system/contracts/chain_management/upgrade_process.md}): deploys the verifiers carrying this
/// branch's VK plus the stage validator and governance timer, and registers the new version with
/// `createNewVerifierOnlyUpgrade`. Facets, chain creation params and L2 code are left as they are.
/// @dev Never broadcasts: the deployments are recorded as CREATE2 factory calldata in `[deploy_calls]`.
/// Entry point: `prepare(inputPath, outputPath)`, both relative to the l1-contracts root.
contract ZKsyncOSVerifierOnlyUpgrade is Script, DefaultCTMUpgrade {
    using stdToml for string;

    /// @notice Input keys this flow adds to the default ones, see `upgrade-envs/<release>/<env>.toml`.
    // solhint-disable-next-line gas-struct-packing
    struct VerifierOnlyInput {
        uint256 expectedOldProtocolVersion;
        bool ownerIsGovernance;
        address deployer;
        uint256[] chainIds;
    }

    VerifierOnlyInput internal verifierOnlyInput;
    bytes32 internal oldVkHash;
    bytes32 internal newVkHash;
    /// @dev abi-encoded `Call[]` per governance stage.
    bytes[3] internal stageCalls;

    function prepare(string memory _inputPath, string memory _outputPath) public {
        string memory toml = vm.readFile(string.concat(vm.projectRoot(), _inputPath));
        address ctm = toml.readAddress("$.ctm");
        verifierOnlyInput.expectedOldProtocolVersion = toml.readUint("$.old_protocol_version");
        verifierOnlyInput.ownerIsGovernance = toml.readBool("$.owner_is_governance");
        verifierOnlyInput.deployer = toml.readAddress("$.deployer");
        verifierOnlyInput.chainIds = toml.readUintArray("$.chain_ids");
        require(IChainTypeManager(ctm).isZKsyncOS(), "vk-only: not a ZKsync OS CTM");

        // The chain creation params stay as they are, so the CTM's current ones are what new chains (and the
        // test chain) are created from.
        (bytes memory creationCut, bytes memory forceDeployments) = GetDiamondCutData._getDiamondCutAndForceDeployment(
            ctm
        );
        require(keccak256(creationCut) == IChainTypeManager(ctm).initialCutHash(), "vk-only: creation cut mismatch");

        initializeWithArgs({
            ctmProxy: ctm,
            bytecodesSupplier: address(0),
            isZKsyncOS: true,
            rollupDAManager: address(0),
            create2FactorySalt: toml.readBytes32("$.create2_factory_salt"),
            newConfigPath: _inputPath,
            _outputPath: _outputPath,
            governance: address(0),
            zkTokenAssetId: abi.decode(forceDeployments, (FixedForceDeploymentsData)).zkTokenAssetId,
            testnetVerifier: toml.readBool("$.testnet_verifier")
        });
        require(address(bridgehub) == toml.readAddress("$.bridgehub"), "vk-only: CTM belongs to another bridgehub");
        require(
            getOldProtocolVersion() == verifierOnlyInput.expectedOldProtocolVersion,
            "vk-only: CTM not on old_protocol_version"
        );
        newlyGeneratedData.diamondCutData = creationCut;
        generatedData.forceDeploymentsData = forceDeployments;
        upgradeConfig.fixedForceDeploymentsDataGenerated = true;

        prepareCTMUpgrade();
        (Call[] memory stage0, Call[] memory stage1, Call[] memory stage2) = prepareDefaultGovernanceCalls();
        stageCalls[0] = abi.encode(stage0);
        stageCalls[1] = abi.encode(stage1);
        stageCalls[2] = abi.encode(stage2);
        prepareDefaultTestUpgradeCalls();
        _saveVerifierOnlyOutput();
    }

    // ======================== Default flow overrides ========================

    /// @inheritdoc DefaultCTMUpgrade
    /// @dev Only the verifiers and the two contracts the governance stages call are deployed.
    function prepareCTMUpgrade() public override {
        deployVerifiers();
        deployUpgradeStageValidator();
        deployGovernanceUpgradeTimer();
        _checkVerificationKey();
        generateUpgradeData();
    }

    /// @inheritdoc DefaultCTMUpgrade
    /// @dev The chain creation cut and force deployments are the CTM's current ones, set in {prepare}.
    function generateUpgradeData() public override {
        require(upgradeConfig.initialized, "Not initialized");
        newlyGeneratedData.upgradeCutData = abi.encode(
            generateUpgradeCutDataFromLocalConfig(ctmAddresses.stateTransition)
        );
        upgradeConfig.upgradeCutPrepared = true;
        saveOutput(upgradeConfig.outputPath);
    }

    /// @inheritdoc DefaultCTMUpgrade
    /// @dev The cut `createNewVerifierOnlyUpgrade` stores: no facets, the CTM's stored default upgrade.
    function generateUpgradeCutDataFromLocalConfig(
        StateTransitionDeployedAddresses memory _stateTransition
    ) public view override returns (Diamond.DiamondCutData memory) {
        require(_stateTransition.defaultUpgrade.code.length > 0, "vk-only: CTM has no default upgrade");
        return
            Diamond.DiamondCutData({
                facetCuts: new Diamond.FacetCut[](0),
                initAddress: _stateTransition.defaultUpgrade,
                initCalldata: abi.encodeCall(IDefaultUpgrade.upgradeVerifierOnly, (getNewProtocolVersion()))
            });
    }

    /// @inheritdoc DefaultCTMUpgrade
    function prepareVersionSpecificStage0GovernanceCallsL1() public view override returns (Call[] memory) {
        return preparePauseGatewayMigrationsCall();
    }

    /// @inheritdoc DefaultCTMUpgrade
    /// @dev No proxy, default upgrade, creation params or DA changes: only the new version.
    function prepareStage1GovernanceCalls() public override returns (Call[] memory calls) {
        calls = new Call[](3);
        calls[0] = prepareGovernanceUpgradeTimerCheckCall()[0];
        calls[1] = prepareCheckMigrationsPausedCalls()[0];
        calls[2] = provideSetNewVersionUpgradeCall()[0];
    }

    /// @inheritdoc DefaultCTMUpgrade
    function provideSetNewVersionUpgradeCall() public view override returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call({
            target: ctmAddresses.stateTransition.proxies.chainTypeManager,
            value: 0,
            data: abi.encodeCall(
                IChainTypeManager.createNewVerifierOnlyUpgrade,
                (
                    getOldProtocolVersion(),
                    UpgradeHelperLib.getOldProtocolDeadline(),
                    getNewProtocolVersion(),
                    ctmAddresses.stateTransition.verifiers.verifier
                )
            )
        });
    }

    /// @inheritdoc DefaultCTMUpgrade
    function prepareVersionSpecificStage2GovernanceCallsL1() public view override returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call({
            target: coreAddresses.bridgehub.proxies.chainAssetHandler,
            value: 0,
            data: abi.encodeCall(IChainAssetHandlerBase.unpauseMigration, ())
        });
    }

    /// @inheritdoc DefaultCTMUpgrade
    /// @dev Only `test_create_chain`, under the ZKsync OS flavour keys protocol-ops gives it when it merges
    /// per-CTM outputs. The per-chain upgrade is covered by the `protocol_ops chain upgrade` bundles, which
    /// also set the upgrade timestamp first; the simulator scenario acknowledges the absence (as for v33).
    function prepareDefaultTestUpgradeCalls() public override {
        string memory o = "test_upgrade_calls";
        vm.serializeAddress(o, "test_create_chain_zkos_caller", getBridgehubAdmin());
        string memory serialized = vm.serializeBytes(
            o,
            "test_create_chain_zkos",
            abi.encode(prepareCreateNewChainCall(getDefaultTestCreateChainId()))
        );
        vm.writeToml(serialized, upgradeConfig.outputPath, ".test_upgrade_calls");
    }

    // ======================== Checks ========================

    /// @dev The deployed VK must be the one the genesis config was released with, and must differ from the
    /// one the CTM runs today.
    function _checkVerificationKey() internal {
        string memory genesis = vm.readFile(Utils.genesisConfigPath(true));
        newVkHash = vm.parseJsonBytes32(genesis, ".prover.recursion_scheduler_level_vk_hash");
        oldVkHash = IVerifier(
            IChainTypeManager(ctmAddresses.stateTransition.proxies.chainTypeManager).protocolVersionVerifier(
                getOldProtocolVersion()
            )
        ).verificationKeyHash();
        require(
            IVerifier(ctmAddresses.stateTransition.verifiers.verifier).verificationKeyHash() == newVkHash,
            "vk-only: deployed VK differs from the genesis config"
        );
        require(oldVkHash != newVkHash, "vk-only: VK unchanged");
    }

    // ======================== Output ========================

    function _upgradeChainCalls(address _chain) internal view returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call({
            target: _chain,
            value: 0,
            data: abi.encodeCall(
                IAdmin.upgradeChainFromVersion,
                (
                    _chain,
                    getOldProtocolVersion(),
                    abi.decode(newlyGeneratedData.upgradeCutData, (Diamond.DiamondCutData))
                )
            )
        });
    }

    function _saveVerifierOnlyOutput() internal {
        string memory path = upgradeConfig.outputPath;
        vm.serializeBytes32("verification_key", "old_vk_hash", oldVkHash);
        vm.writeToml(vm.serializeBytes32("verification_key", "new_vk_hash", newVkHash), path, ".verification_key");
        vm.writeToml(_serializeDeployCalls(), path, ".deploy_calls");
        if (verifierOnlyInput.ownerIsGovernance) {
            vm.writeToml(_serializeGovernanceOperations(), path, ".governance_operations");
        }
        vm.writeToml(_serializeChainUpgrades(), path, ".chain_upgrades");
    }

    /// @dev The CREATE2 factory calls the deployments above made, in order. Any sender can submit them.
    function _serializeDeployCalls() internal returns (string memory) {
        (, string memory plonkName) = DeployCTML1OrGateway.resolve(true, CTMContract.VerifierPlonk);
        (, string memory verifierName) = DeployCTML1OrGateway.resolveMainVerifier(true, config.testnetVerifier);
        string[] memory names = new string[](4);
        names[0] = plonkName;
        names[1] = verifierName;
        names[2] = "UpgradeStageValidator";
        names[3] = "GovernanceUpgradeTimer";

        (address factory, bytes32 salt) = getCreate2FactoryParams();
        Call[] memory calls = new Call[](names.length);
        for (uint256 i = 0; i < names.length; ++i) {
            bytes memory initCode = abi.encodePacked(
                getCreationCode(names[i], false),
                getCreationCalldata(names[i], false)
            );
            require(
                vm.computeCreate2Address(salt, keccak256(initCode), factory).code.length > 0,
                "vk-only: deploy call does not match the deployment"
            );
            calls[i] = Call({
                target: factory,
                value: 0,
                data: Utils.getDeterministicCreate2FactoryCalldata(salt, initCode)
            });
        }
        vm.serializeAddress("deploy_calls", "deployer", verifierOnlyInput.deployer);
        vm.serializeString("deploy_calls", "contracts", names);
        return vm.serializeBytes("deploy_calls", "calls", abi.encode(calls));
    }

    /// @dev `Governance.scheduleTransparent(op, minDelay)` then `execute(op)`, one operation per stage. The salt
    /// is derived from the CREATE2 salt and the stage, so no two operations share an id.
    function _serializeGovernanceOperations() internal returns (string memory out) {
        address governance = config.ownerAddress;
        uint256 delay = IGovernanceMinDelay(governance).minDelay();
        (, bytes32 salt) = getCreate2FactoryParams();
        string memory o = "governance_operations";
        vm.serializeAddress(o, "governance_owner", IOwnable(governance).owner());
        vm.serializeUint(o, "delay", delay);
        for (uint256 stage = 0; stage < 3; ++stage) {
            IGovernance.Operation memory op = IGovernance.Operation({
                calls: abi.decode(stageCalls[stage], (Call[])),
                predecessor: bytes32(0),
                salt: keccak256(abi.encode(salt, "governance stage", stage))
            });
            string memory prefix = string.concat("stage", vm.toString(stage));
            vm.serializeBytes32(o, string.concat(prefix, "_operation_id"), IGovernance(governance).hashOperation(op));
            vm.serializeBytes(
                o,
                string.concat(prefix, "_schedule_calldata"),
                abi.encodeCall(IGovernance.scheduleTransparent, (op, delay))
            );
            out = vm.serializeBytes(
                o,
                string.concat(prefix, "_execute_calldata"),
                abi.encodeCall(IGovernance.execute, (op))
            );
        }
    }

    function _serializeChainUpgrades() internal returns (string memory out) {
        for (uint256 i = 0; i < verifierOnlyInput.chainIds.length; ++i) {
            uint256 chainId = verifierOnlyInput.chainIds[i];
            require(
                bridgehub.chainTypeManager(chainId) == ctmAddresses.stateTransition.proxies.chainTypeManager,
                "vk-only: chain on another CTM"
            );
            address chain = bridgehub.getZKChain(chainId);
            require(
                IGetters(chain).getProtocolVersion() == getOldProtocolVersion(),
                "vk-only: chain not on old version"
            );
            address chainAdmin = IGetters(chain).getAdmin();
            string memory key = vm.toString(chainId);
            string memory o = string.concat("chain_upgrade_", key);
            vm.serializeAddress(o, "chain", chain);
            vm.serializeAddress(o, "chain_admin", chainAdmin);
            vm.serializeAddress(o, "chain_admin_owner", IOwnable(chainAdmin).owner());
            string memory entry = vm.serializeBytes(
                o,
                "chain_admin_calldata",
                abi.encodeCall(IChainAdmin.multicall, (_upgradeChainCalls(chain), true))
            );
            out = vm.serializeString("chain_upgrades", key, entry);
        }
    }
}
