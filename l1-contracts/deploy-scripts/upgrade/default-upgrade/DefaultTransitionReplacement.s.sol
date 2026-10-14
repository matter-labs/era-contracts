// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable gas-custom-errors

import {stdToml} from "forge-std/StdToml.sol";

import {Call} from "contracts/governance/Common.sol";
import {IUpgradeExecutorBase} from "contracts/governance/IUpgradeExecutorBase.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {ICTMTransition} from "contracts/upgrades/registry/objects/ICTMTransition.sol";
import {TransitionManifest} from "contracts/upgrades/registry/RegistryTypes.sol";

import {DefaultCTMUpgrade} from "./DefaultCTMUpgrade.s.sol";
import {ExternalActionsLib} from "./ExternalActionsLib.sol";
import {UpgradeKind} from "./UpgradeParams.sol";

/// @notice Prepares the replacement of a transition already committed for a departed version —
///         `ChainTypeManager.replaceUpgradeTransition`, see
///         {protocol-docs/ecosystem-upgrade-coordination.md#replacing-a-committed-transition}. It deploys
///         the replacement `CTMTransition` the way every prepare deploys a transition (this run's
///         engine and authored L2 side, published on the CTM's supplier) from the replaced one's source
///         release and pinned deadline onto the release a chain continues from, and declares ONE
///         governance call: `CTMUpgradeExecutor.forward([CTM.replaceUpgradeTransition(expected,
///         replacement)])`, optionally followed in the same `forward` by `setProtocolVersionDeadline`.
/// @dev Run as the CTM prepare of `upgrade-prepare-all` (`--ctm-script-path`); the upgrade input names
///      the replaced transition in `[transition_replacement] replaced_transition` and may set
///      `[transition_replacement] protocol_version_deadline`. A version script overrides
///      {authorL2Side}, {deployUsedUpgradeContract} or {replacementTargetVersion} to say what the
///      replacement repairs. No release, operation or timer is deployed: nothing about the CTM's own
///      version or release moves.
contract DefaultTransitionReplacement is DefaultCTMUpgrade {
    using stdToml for string;

    /// @notice The transition committed for the departure this run repairs — the compare-and-replace
    ///         `expected`.
    ICTMTransition public replacedTransition;

    /// @notice Whether the same `forward` also moves the departing version's deadline.
    bool public setsProtocolVersionDeadline;

    /// @notice The deadline it moves it to, when {setsProtocolVersionDeadline}.
    uint256 public newProtocolVersionDeadline;

    /// @inheritdoc DefaultCTMUpgrade
    function upgradeKind() public pure override returns (UpgradeKind) {
        return UpgradeKind.TransitionReplacement;
    }

    /// @notice Names the transition this run replaces; the departing and target versions follow from
    ///         it. Read from the upgrade input in production; in-forge harnesses call it directly.
    /// @param _replaced The transition committed for the departure.
    function setReplacedTransition(address _replaced) public {
        require(_replaced.code.length != 0, "the replaced transition has no code");
        replacedTransition = ICTMTransition(_replaced);
        newConfig.oldProtocolVersion = replacedTransition.oldProtocolVersion();
        setNewProtocolVersion(replacementTargetVersion());
    }

    /// @notice Makes the replacement's `forward` also move the departing version's deadline.
    /// @param _deadline The new deadline of the departing version.
    function setReplacementDeadline(uint256 _deadline) public {
        setsProtocolVersionDeadline = true;
        newProtocolVersionDeadline = _deadline;
    }

    /// @notice The version the replacement lands on: the replaced transition's own target by default.
    ///         A version script may retarget it past that, onto a later continuation release.
    function replacementTargetVersion() public view virtual returns (uint256) {
        return replacedTransition.newProtocolVersion();
    }

    /// @notice The release a chain landing on `_targetVersion` continues from — the only destination
    ///         `replaceUpgradeTransition` accepts: the current release at the CTM's version, otherwise
    ///         the source release of the transition committed onward from `_targetVersion`.
    /// @param _targetVersion The version the replacement lands on.
    function continuationRelease(uint256 _targetVersion) public view returns (address) {
        IChainTypeManager ctm = IChainTypeManager(ctmAddresses.stateTransition.proxies.chainTypeManager);
        if (_targetVersion == ctm.protocolVersion()) {
            return ctm.currentRelease();
        }
        address onward = ctm.upgradeTransition(_targetVersion);
        require(onward != address(0), "nothing is committed onward from the target version");
        return ICTMTransition(onward).fromRelease();
    }

    /// @notice The replacement's full preparation: the authored L2 side published, the engine, the
    ///         replacement transition, and the one governance call that installs it.
    function prepareCTMUpgrade() public override {
        require(address(replacedTransition) != address(0), "no transition to replace: set the replaced transition");
        IChainTypeManager ctm = IChainTypeManager(ctmAddresses.stateTransition.proxies.chainTypeManager);
        require(
            ctm.upgradeTransition(replacedTransition.oldProtocolVersion()) == address(replacedTransition),
            "the replaced transition is not the one committed for its departure"
        );
        prepareL2Side();
        upgradeAddresses.upgradeEngine = deployUsedUpgradeContract();
        deployReplacementTransition();
        _declareReplacementCall();
        saveOutput(upgradeConfig.outputPath);
    }

    /// @notice Deploys the replacement: the replaced transition's source release, pinned deadline and
    ///         upgrade timestamp, this run's engine and L2 plan, landing on the continuation release.
    function deployReplacementTransition() public virtual {
        ICTMTransition replaced = replacedTransition;
        TransitionManifest memory manifest = TransitionManifest({
            fromRelease: replaced.fromRelease(),
            newRelease: continuationRelease(replacementTargetVersion()),
            upgradeEngine: committedUpgradeEngine(),
            oldProtocolVersionDeadline: replaced.oldProtocolVersionDeadline(),
            upgradeTimestamp: replaced.upgradeTimestamp(),
            l2Plan: authoredL2Plan()
        });
        require(
            keccak256(abi.encode(manifest)) != replaced.manifestHash(),
            "the replacement pins exactly the edge it replaces"
        );
        upgradeAddresses.ctmTransition = deployTransition(manifest);
        ctmAddresses.stateTransition.currentRelease = manifest.newRelease;
    }

    /// @dev Declares the single stage-1 call; the governance bundles are rendered from it.
    function _declareReplacementCall() private {
        address ctm = ctmAddresses.stateTransition.proxies.chainTypeManager;
        uint256 departing = replacedTransition.oldProtocolVersion();
        Call[] memory inner = new Call[](setsProtocolVersionDeadline ? 2 : 1);
        inner[0] = Call({
            target: ctm,
            value: 0,
            data: abi.encodeCall(
                IChainTypeManager.replaceUpgradeTransition,
                (replacedTransition, ICTMTransition(upgradeAddresses.ctmTransition))
            )
        });
        if (setsProtocolVersionDeadline) {
            inner[1] = Call({
                target: ctm,
                value: 0,
                data: abi.encodeCall(
                    IChainTypeManager.setProtocolVersionDeadline,
                    (departing, newProtocolVersionDeadline)
                )
            });
        }
        declareExternalAction(
            ExternalActionsLib.PHASE_STAGE_1,
            string.concat("replace the committed transition departing ", vm.toString(departing)),
            "CTM executor owner (governance)",
            Call({
                target: boundCTMUpgradeExecutor(),
                value: 0,
                data: abi.encodeCall(IUpgradeExecutorBase.forward, (inner))
            })
        );
    }

    /// @dev Reads the replacement inputs after the shared configuration.
    function initializeConfigFromArgs(
        address _ctmProxy,
        address _rollupDAManager,
        bytes32 _create2FactorySalt,
        string memory _newConfigPath,
        address _governance,
        bytes32 _zkTokenAssetId,
        bool _testnetVerifier
    ) internal override {
        super.initializeConfigFromArgs({
            ctmProxy: _ctmProxy,
            rollupDAManager: _rollupDAManager,
            create2FactorySalt: _create2FactorySalt,
            newConfigPath: _newConfigPath,
            governance: _governance,
            zkTokenAssetId: _zkTokenAssetId,
            testnetVerifier: _testnetVerifier
        });
        string memory toml = vm.readFile(_newConfigPath);
        if (toml.keyExists("$.transition_replacement.replaced_transition")) {
            setReplacedTransition(toml.readAddress("$.transition_replacement.replaced_transition"));
        }
        if (toml.keyExists("$.transition_replacement.protocol_version_deadline")) {
            setReplacementDeadline(toml.readUint("$.transition_replacement.protocol_version_deadline"));
        }
    }

    /// @dev Names both sides of the compare-and-replace beside the usual registry fields.
    function saveOutput(string memory _outputPath) internal override {
        vm.serializeAddress("registry", "replaced_transition_addr", address(replacedTransition));
        vm.serializeAddress("registry", "replacement_transition_addr", upgradeAddresses.ctmTransition);
        super.saveOutput(_outputPath);
    }
}
