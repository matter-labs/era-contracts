// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {EnumerableMap} from "@openzeppelin/contracts-v4/utils/structs/EnumerableMap.sol";
import {SafeCast} from "@openzeppelin/contracts-v4/utils/math/SafeCast.sol";

import {Diamond} from "./libraries/Diamond.sol";
import {DiamondProxy} from "./chain-deps/DiamondProxy.sol";
import {IAdmin} from "./chain-interfaces/IAdmin.sol";
import {IMigrator} from "./chain-interfaces/IMigrator.sol";
import {IDiamondInit} from "./chain-interfaces/IDiamondInit.sol";
import {IExecutor} from "./chain-interfaces/IExecutor.sol";
import {ChainTypeManagerInitializeData, IChainTypeManager} from "./IChainTypeManager.sol";
import {ICTMRelease} from "../upgrades/registry/objects/ICTMRelease.sol";
import {ICTMTransition} from "../upgrades/registry/objects/ICTMTransition.sol";
import {CTMUpgradeComposer} from "../upgrades/registry/libraries/CTMUpgradeComposer.sol";
import {IDefaultUpgrade} from "../upgrades/IDefaultUpgrade.sol";
import {IZKChain} from "./chain-interfaces/IZKChain.sol";
import {FeeParams} from "./chain-deps/ZKChainStorage.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {DEFAULT_L2_LOGS_TREE_ROOT_HASH, EMPTY_STRING_KECCAK, L2_TO_L1_LOG_SERIALIZE_SIZE} from "../common/Config.sol";
import {AdminZero, OutdatedProtocolVersion} from "./L1StateTransitionErrors.sol";
import {ProtocolVersionTooSmall} from "../upgrades/ZkSyncUpgradeErrors.sol";
import {
    ChainAlreadyLive,
    MigrationsNotPaused,
    EmptyBytes32,
    RegistryReleaseCodehashAlreadySet,
    NoCommittedUpgradeCutForVersion,
    Unauthorized,
    ZeroAddress
} from "../common/L1ContractErrors.sol";
import {SemVer} from "../common/libraries/SemVer.sol";
import {IL1Bridgehub} from "../core/bridgehub/IL1Bridgehub.sol";
import {IChainAssetHandlerBase} from "../core/chain-asset-handler/IChainAssetHandler.sol";

import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {TxStatus} from "../common/Messaging.sol";
import {CodehashPinLib} from "../upgrades/registry/libraries/CodehashPinLib.sol";

/// @title Chain Type Manager Base contract
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Base contract for Chain Type Managers with common functionality
abstract contract ChainTypeManagerBase is IChainTypeManager, ReentrancyGuard, Ownable2StepUpgradeable {
    using CodehashPinLib for address;

    using EnumerableMap for EnumerableMap.UintToAddressMap;

    /// @notice Address of the bridgehub
    address public immutable BRIDGE_HUB;

    /// @notice Address of the interop center
    address public immutable INTEROP_CENTER;

    /// @notice Address of the L1 bytecodes supplier used for upgrades
    address public immutable L1_BYTECODES_SUPPLIER;

    /// @notice Address of the permissionless validator used in Priority Mode
    address public immutable PERMISSIONLESS_VALIDATOR;

    /// @notice The map from chainId => zkChain contract
    EnumerableMap.UintToAddressMap internal __DEPRECATED_zkChainMap;

    /// @dev Deprecated. Genesis batch zero, the initial diamond cut hash and the L1 genesis
    ///      upgrade address are no longer stored: they are read from the genesis `CTMRegistry`
    ///      (see `storedBatchZero()` / `l1GenesisUpgrade()` and the `_deployNewChain` cut). Slots
    ///      retained to preserve the upgradeable storage layout.
    // slither-disable-next-line constable-states
    bytes32 internal __DEPRECATED_storedBatchZero;

    // slither-disable-next-line constable-states
    bytes32 internal __DEPRECATED_initialCutHash;

    // slither-disable-next-line constable-states
    address internal __DEPRECATED_l1GenesisUpgrade;

    /// @dev The current packed protocolVersion. To access human-readable version, use `getSemverProtocolVersion` function.
    uint256 public protocolVersion;

    /// @dev Deadlines for versions with no committed transition: versions departed via the legacy
    ///      cut-taking path (the bootstrap edge and everything before it). Registry-driven edges
    ///      never write here — their deadline lives on the transition, and the
    ///      {protocolVersionDeadline} view resolves it from there.
    mapping(uint256 _protocolVersion => uint256) internal __DEPRECATED_protocolVersionDeadline;

    /// @dev The validatorTimelock contract address.
    /// @dev Note, that address contains validator timelock for pre-v29 protocol versions. It is deprecated and will be removed in the future.
    address internal __DEPRECATED_validatorTimelock;

    /// @dev Deprecated. Written only by the legacy cut-taking commit path: pre-v32 Admin facets
    ///      crossing that edge verify the handed cut bytes against it (served through the
    ///      {upgradeCutHash} view). Registry-driven edges commit only the transition
    ///      ({upgradeTransition}); chains read {upgradeCutForVersion}.
    mapping(uint256 protocolVersion => bytes32 cutHash) internal __DEPRECATED_upgradeCutHash;

    /// @dev The address used to manage non critical updates
    address public admin;

    /// @dev The address to accept the admin role
    address private pendingAdmin;

    /// @dev Deprecated. The genesis force-deployments are read from the registry
    ///      (`fixedForceDeploymentsData`); no hash of a caller-supplied copy is stored. Slot
    ///      retained to preserve the upgradeable storage layout.
    // slither-disable-next-line constable-states
    bytes32 internal __DEPRECATED_initialForceDeploymentHash;

    /// @dev The contract, that notifies server about l1 changes
    address public serverNotifierAddress;

    /// @dev The address of the post-V29 upgradeable validatorTimelock.
    /// @dev Both validatorTimelock and validatorTimelockPostV29 getters are available for backward compatibility of nodes that rely on the validatorTimelock address being available.
    address public validatorTimelockPostV29;

    /// @dev Deprecated. Off-chain tooling used it to locate the `NewUpgradeCutData` log for a
    ///      version; the legacy cut-taking commit still writes it (its tooling reads it for the
    ///      bootstrap edge), registry-driven commits do not — the cut is read from
    ///      {upgradeCutForVersion}, no log archaeology needed. Served read-only
    ///      ({upgradeCutDataBlock}) otherwise.
    mapping(uint256 protocolVersion => uint256) internal __DEPRECATED_upgradeCutDataBlock;

    /// @dev Deprecated, no longer written. Off-chain tooling used it to locate the block where
    ///      chain-creation params changed; under the registry model the genesis data is read
    ///      directly from `currentRelease` and pin moves are announced by `NewCurrentRelease`.
    ///      Served read-only ({newChainCreationParamsBlock}) for versions written pre-v34.
    // Never written by THIS implementation by design — live chains carry pre-v34 values in it.
    // slither-disable-next-line uninitialized-state
    mapping(uint256 protocolVersion => uint256) internal __DEPRECATED_newChainCreationParamsBlock;

    /// @dev Retained only to preserve the upgradeable storage layout. The verifier is part of the
    /// installed chain state and is pinned by the release (`ICTMRelease.verifier`), so both the
    /// genesis path and the upgrade path read it from the release they resolve to.
    mapping(uint256 protocolVersion => address) internal __DEPRECATED_protocolVersionVerifier;

    /// @dev The release whose post-upgrade state is used for new-chain genesis. A release is not
    /// version-keyed at read time, so patch upgrades can reuse it without making genesis data
    /// unanswerable.
    address public currentRelease;

    /// @notice `EXTCODEHASH` of the audited `CTMRelease`. Every release this CTM pins must run
    ///         exactly that code (see `_storeCurrentRelease`). Set once at initialization.
    bytes32 public releaseCodehash;

    /// @notice The transition committed for chains departing from a given protocol version. The
    ///         ONLY commitment for registry-driven edges: {upgradeCutForVersion} derives the cut
    ///         from it, so chains are never handed cut bytes. `upgradeCutHash` remains only for
    ///         chains on pre-v32 Admin facets, whose handed-cut path verifies against it.
    mapping(uint256 oldProtocolVersion => address transition) public upgradeTransition;

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    /// @dev Note, that while the contract does not use `nonReentrant` modifier, we still keep the `reentrancyGuardInitializer`
    /// here for two reasons:
    /// - It prevents the function from being called twice (including in the proxy impl).
    /// - It makes the local version consistent with the one in production, which already had the reentrancy guard
    /// initialized.
    constructor(
        address _bridgehub,
        address _interopCenter,
        address _l1BytecodesSupplier,
        address _permissionlessValidator
    ) reentrancyGuardInitializer {
        BRIDGE_HUB = _bridgehub;
        INTEROP_CENTER = _interopCenter;
        L1_BYTECODES_SUPPLIER = _l1BytecodesSupplier;
        PERMISSIONLESS_VALIDATOR = _permissionlessValidator;

        // While this does not provide a protection in the production, it is needed for local testing
        // Length of the L2Log encoding should not be equal to the length of other L2Logs' tree nodes preimages
        assert(L2_TO_L1_LOG_SERIALIZE_SIZE != 2 * 32);

        _disableInitializers();
    }

    /// @notice only the bridgehub can call
    modifier onlyBridgehub() {
        if (msg.sender != BRIDGE_HUB) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice the admin can call, for non-critical updates
    modifier onlyOwnerOrAdmin() {
        if (msg.sender != admin && msg.sender != owner()) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice only the chain asset handler can call
    modifier onlyChainAssetHandler() {
        if (msg.sender != IL1Bridgehub(BRIDGE_HUB).chainAssetHandler()) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @return flag whether CTM is for ZKsync OS or Era VM.
    /// @dev To be defined in derived contracts.
    function isZKsyncOS() external pure virtual returns (bool);

    /// @return The tuple of (major, minor, patch) protocol version.
    function getSemverProtocolVersion() external view returns (uint32, uint32, uint32) {
        // slither-disable-next-line unused-return
        return SemVer.unpackSemVer(SafeCast.toUint96(protocolVersion));
    }

    /// @notice return the chain contract address for a chainId
    function getZKChain(uint256 _chainId) public view returns (address) {
        return IL1Bridgehub(BRIDGE_HUB).getZKChain(_chainId);
    }

    /// @notice return the chain contract address for a chainId
    /// @notice Do not use! use getZKChain instead. This will be removed.
    function getZKChainLegacy(uint256 _chainId) public view returns (address chainAddress) {
        // slither-disable-next-line unused-return
        (, chainAddress) = __DEPRECATED_zkChainMap.tryGet(_chainId);
    }

    /// @notice Returns the address of the ZK chain admin with the corresponding chainID.
    /// @notice Not related to the CTM, but it is here for legacy reasons.
    /// @param _chainId the chainId of the chain
    function getChainAdmin(uint256 _chainId) external view override returns (address) {
        return IZKChain(getZKChain(_chainId)).getAdmin();
    }

    /// @dev initialize
    /// @dev Note, that while the contract does not use `nonReentrant` modifier, we still keep the `reentrancyGuardInitializer`
    /// here for two reasons:
    /// - It prevents the function from being called twice (including in the proxy impl).
    /// - It makes the local version consistent with the one in production, which already had the reentrancy guard
    /// initialized.
    function initialize(ChainTypeManagerInitializeData calldata _initializeData) external reentrancyGuardInitializer {
        if (_initializeData.owner == address(0)) {
            revert ZeroAddress();
        }
        if (_initializeData.validatorTimelock == address(0)) {
            revert ZeroAddress();
        }
        if (_initializeData.serverNotifier == address(0)) {
            revert ZeroAddress();
        }
        _transferOwnership(_initializeData.owner);

        // No deadline write: the current version resolves to `type(uint256).max` in
        // {protocolVersionDeadline} until a transition departing from it is committed.
        protocolVersion = _initializeData.protocolVersion;
        validatorTimelockPostV29 = _initializeData.validatorTimelock;
        serverNotifierAddress = _initializeData.serverNotifier;

        if (_initializeData.releaseCodehash == bytes32(0)) {
            revert EmptyBytes32();
        }
        releaseCodehash = _initializeData.releaseCodehash;
        emit NewReleaseCodehash(_initializeData.releaseCodehash);
        _setCurrentRelease(_initializeData.currentRelease);
    }

    /// @dev Overridden per VM to validate release compatibility and genesis params.
    function _setCurrentRelease(address _release) internal virtual;

    function setCurrentRelease(address _release) external onlyOwner {
        _setCurrentRelease(_release);
    }

    /// @notice One-shot migration setter for the canonical release codehash. Freshly initialized
    ///         CTMs receive it in `initialize`; CTMs MIGRATED from pre-registry versions (whose
    ///         storage predates the field) set it during their migration, BEFORE the first
    ///         `setCurrentRelease` — release provenance cannot be checked against a zero factory.
    /// @dev Deliberately NOT a rotation mechanism: the factory is the provenance anchor every
    ///      pinned release is attested against, so RE-POINTING it would retroactively change what
    ///      "factory-attested" means. It can only fill the gap left by migration. A genuine factory
    ///      migration needs its own explicitly named entrypoint whose semantics governance reviews
    ///      on its own terms.
    /// @dev Re-setting the anchor to the value it already holds is a no-op rather than a revert, so
    ///      one upgrade bundle works against both a migrated CTM (anchor still zero) and an
    ///      already-anchored one without the calldata having to predict which it is.
    function setReleaseCodehash(bytes32 _releaseCodehash) external onlyOwner {
        if (_releaseCodehash == bytes32(0)) {
            revert EmptyBytes32();
        }
        bytes32 current = releaseCodehash;
        if (current == _releaseCodehash) {
            return;
        }
        if (current != bytes32(0)) {
            revert RegistryReleaseCodehashAlreadySet(current);
        }
        releaseCodehash = _releaseCodehash;
        emit NewReleaseCodehash(_releaseCodehash);
    }

    /// @dev The pinned codehash is CTM state, never authored inside permissionless transition
    ///      manifests, so a manifest cannot smuggle in an arbitrary (possibly mutable)
    ///      `ICTMRelease` implementation. Callers check this BEFORE reading anything out of the
    ///      candidate: a non-release answers those reads with an empty revert.
    function _requireGenuineRelease(address _release) internal view {
        _release.requirePin(releaseCodehash);
    }

    function _storeCurrentRelease(address _release) internal {
        if (_release == address(0)) {
            revert ZeroAddress();
        }
        // The single authoritative point every release passes through (bootstrap initialize and
        // every later transition alike), so provenance holds even for a path that skipped the
        // fail-fast check in `_setCurrentRelease`.
        _requireGenuineRelease(_release);
        currentRelease = _release;
        emit NewCurrentRelease(protocolVersion, _release);
    }

    /// @notice The L1 genesis upgrade contract new chains run at creation, read from the genesis
    ///         registry (used to set chainId + force-deploy the L2 system contracts).
    function l1GenesisUpgrade() public view returns (address genesisUpgrade) {
        // slither-disable-next-line unused-return
        (genesisUpgrade, , , ) = ICTMRelease(currentRelease).genesisParams();
    }

    /// @notice The genesis (batch zero) stored-batch hash new chains start from — derived from
    ///         the genesis params the registry pins, so it stays consistent with the registry.
    function storedBatchZero() public view returns (bytes32) {
        // slither-disable-next-line unused-return
        (
            ,
            bytes32 genesisBatchHash,
            bytes32 genesisBatchCommitment,
            uint64 genesisIndexRepeatedStorageChanges
        ) = ICTMRelease(currentRelease).genesisParams();
        IExecutor.StoredBatchInfo memory batchZero = IExecutor.StoredBatchInfo({
            batchNumber: 0,
            batchHash: genesisBatchHash,
            indexRepeatedStorageChanges: genesisIndexRepeatedStorageChanges,
            numberOfLayer1Txs: 0,
            priorityOperationsHash: EMPTY_STRING_KECCAK,
            l2LogsTreeRoot: DEFAULT_L2_LOGS_TREE_ROOT_HASH,
            dependencyRootsRollingHash: bytes32(0),
            timestamp: 0,
            commitment: genesisBatchCommitment
        });
        return keccak256(abi.encode(batchZero));
    }

    /// @notice Starts the transfer of admin rights. Only the current admin can propose a new pending one.
    /// @notice New admin can accept admin rights by calling `acceptAdmin` function.
    /// @param _newPendingAdmin Address of the new admin
    /// @dev Please note, if the owner wants to enforce the admin change it must execute both `setPendingAdmin` and
    /// `acceptAdmin` atomically. Otherwise `admin` can set different pending admin and so fail to accept the admin rights.
    function setPendingAdmin(address _newPendingAdmin) external onlyOwnerOrAdmin {
        // Save previous value into the stack to put it into the event later
        address oldPendingAdmin = pendingAdmin;
        // Change pending admin
        pendingAdmin = _newPendingAdmin;
        emit NewPendingAdmin(oldPendingAdmin, _newPendingAdmin);
    }

    /// @notice Accepts transfer of admin rights. Only pending admin can accept the role.
    function acceptAdmin() external {
        // Only proposed by current admin address can claim the admin rights
        if (msg.sender != pendingAdmin) {
            revert Unauthorized(msg.sender);
        }

        address previousAdmin = admin;
        admin = msg.sender;
        delete pendingAdmin;

        emit NewPendingAdmin(msg.sender, address(0));
        emit NewAdmin(previousAdmin, msg.sender);
    }

    /// @dev Used to set legacy validatorTimelock.
    /// @dev Note, that the validator timelock that this function sets is only used for pre-v29 protocol versions.
    /// It is kept only for convenience.
    /// @param _validatorTimelock the new validatorTimelock address
    function setLegacyValidatorTimelock(address _validatorTimelock) external onlyOwner {
        address oldValidatorTimelock = __DEPRECATED_validatorTimelock;
        __DEPRECATED_validatorTimelock = _validatorTimelock;
        emit NewValidatorTimelock(oldValidatorTimelock, _validatorTimelock);
    }

    /// @dev Used to set post-V29 validator timelock. Cannot do it during initialization, as validatorTimelockPostV29 is deployed after CTM.
    /// @param _validatorTimelockPostV29 the new post-V29 upgradeable validatorTimelock address
    function setValidatorTimelockPostV29(address _validatorTimelockPostV29) external onlyOwner {
        address oldValidatorTimelockPostV29 = validatorTimelockPostV29;
        validatorTimelockPostV29 = _validatorTimelockPostV29;
        emit NewValidatorTimelockPostV29(oldValidatorTimelockPostV29, _validatorTimelockPostV29);
    }

    /// @dev set ServerNotifier.
    /// @param _serverNotifier the new serverNotifier address
    function setServerNotifier(address _serverNotifier) external onlyOwnerOrAdmin {
        address oldServerNotifier = serverNotifierAddress;
        serverNotifierAddress = _serverNotifier;
        emit NewServerNotifier(oldServerNotifier, _serverNotifier);
    }

    /// @notice Commits one registry-driven transition: the version edge, the schedule and the
    ///         upgrade cut all come from the pinned object, so they cannot disagree with each other.
    /// @param _transition The write-once transition governance approved.
    /// @dev The cut is DERIVED here rather than supplied: it is a pure function of the transition
    ///      (`upgradeEngine.upgradeFromTransition(transition)` over no facet cuts), so passing it
    ///      would only add a second, unverifiable copy of data this contract can compute.
    /// @dev No factory attestation is performed here. The caller is the owner, which under the
    ///      registry model is the bound `CTMUpgradeExecutor` that already rejects transitions its
    ///      immutable factory did not deploy. This is strictly narrower than the cut-taking
    ///      entrypoint below, which accepts arbitrary calldata from the same owner.
    function setNewVersionUpgradeFromTransition(ICTMTransition _transition) external onlyOwner {
        uint256 oldProtocolVersion = _transition.oldProtocolVersion();
        uint256 newProtocolVersion = _transition.newProtocolVersion();
        _commitVersionEdge(oldProtocolVersion, newProtocolVersion);
        // The transition is the ONLY commitment: the cut derives from it on read
        // (`upgradeCutForVersion`), its deadline resolves from it (`protocolVersionDeadline`),
        // so neither the deprecated `upgradeCutHash` nor the legacy deadline storage is written.
        upgradeTransition[oldProtocolVersion] = address(_transition);
        emit NewUpgradeTransition(oldProtocolVersion, address(_transition));
        // Off-chain consumers keep receiving the composed cut through the same event as before.
        emit NewUpgradeCutData(newProtocolVersion, _transitionUpgradeCut(_transition));
    }

    /// @dev set New Version with upgrade from old version
    /// @param _cutData the new diamond cut data
    /// @param _oldProtocolVersion the old protocol version
    /// @param _oldProtocolVersionDeadline the deadline for the old protocol version
    /// @param _newProtocolVersion the new protocol version
    /// @dev Kept for edges whose cut cannot be derived — the pre-registry bootstrap, whose departing
    ///      version has no `fromRelease` to diff against. Registry-driven upgrades use
    ///      {setNewVersionUpgradeFromTransition}.
    function setNewVersionUpgrade(
        Diamond.DiamondCutData calldata _cutData,
        uint256 _oldProtocolVersion,
        uint256 _oldProtocolVersionDeadline,
        uint256 _newProtocolVersion
    ) external onlyOwner {
        _commitVersionEdge(_oldProtocolVersion, _newProtocolVersion);
        // The departing version has no transition to resolve a deadline from, so this path is the
        // one writer of the legacy deadline storage.
        __DEPRECATED_protocolVersionDeadline[_oldProtocolVersion] = _oldProtocolVersionDeadline;
        emit UpdateProtocolVersionDeadline(_oldProtocolVersion, _oldProtocolVersionDeadline);
        setUpgradeDiamondCutInner(_cutData, _oldProtocolVersion);
        // Emit event with backward compatible hack.
        emit NewUpgradeCutData(_newProtocolVersion, _cutData);
    }

    /// @dev The version-edge commit shared by both entrypoints: checks the edge and moves
    ///      `protocolVersion` forward.
    /// @dev Note: non-sequential protocol versions are allowed (e.g., minor/patch jumps).
    function _commitVersionEdge(uint256 _oldProtocolVersion, uint256 _newProtocolVersion) internal {
        // Migrations must be paused before setting new version upgrades
        if (!IChainAssetHandlerBase(IL1Bridgehub(BRIDGE_HUB).chainAssetHandler()).migrationPaused()) {
            revert MigrationsNotPaused();
        }
        uint256 previousProtocolVersion = protocolVersion;
        // Explicitly verify that _oldProtocolVersion matches the current one.
        if (previousProtocolVersion != _oldProtocolVersion) {
            revert OutdatedProtocolVersion(previousProtocolVersion, _oldProtocolVersion);
        }
        // The version only ever moves forward. Chains enforce this individually at execution
        // (`BaseZkSyncUpgrade._setNewProtocolVersion`); without this check the CTM could commit
        // to a downgrade/no-op version that every chain would later reject.
        if (_newProtocolVersion <= _oldProtocolVersion) {
            revert ProtocolVersionTooSmall(_oldProtocolVersion, _newProtocolVersion);
        }
        protocolVersion = _newProtocolVersion;
        emit NewProtocolVersion(previousProtocolVersion, _newProtocolVersion);
    }

    /// @inheritdoc IChainTypeManager
    function protocolVersionDeadline(uint256 _protocolVersion) public view returns (uint256) {
        address transition = upgradeTransition[_protocolVersion];
        if (transition != address(0)) {
            return ICTMTransition(transition).oldProtocolVersionDeadline();
        }
        if (_protocolVersion == protocolVersion) {
            return type(uint256).max;
        }
        return __DEPRECATED_protocolVersionDeadline[_protocolVersion];
    }

    /// @notice Deprecated. The block of a LEGACY cut commit, where its tooling finds the
    ///         `NewUpgradeCutData` log; zero for registry-driven edges (read the cut from
    ///         {upgradeCutForVersion} instead).
    function upgradeCutDataBlock(uint256 _protocolVersion) public view returns (uint256) {
        return __DEPRECATED_upgradeCutDataBlock[_protocolVersion];
    }

    /// @notice Deprecated. The block where pre-v34 code recorded a chain-creation-params change;
    ///         nothing writes it any more — genesis data is read from `currentRelease`.
    function newChainCreationParamsBlock(uint256 _protocolVersion) public view returns (uint256) {
        return __DEPRECATED_newChainCreationParamsBlock[_protocolVersion];
    }

    /// @dev check that the protocolVersion is active
    /// @param _protocolVersion the protocol version to check
    function protocolVersionIsActive(uint256 _protocolVersion) external view override returns (bool) {
        return block.timestamp <= protocolVersionDeadline(_protocolVersion);
    }

    /// @dev set upgrade for some protocolVersion
    /// @param _cutData the new diamond cut data
    /// @param _oldProtocolVersion the old protocol version
    function setUpgradeDiamondCut(
        Diamond.DiamondCutData calldata _cutData,
        uint256 _oldProtocolVersion
    ) external onlyOwner {
        setUpgradeDiamondCutInner(_cutData, _oldProtocolVersion);
    }

    /// @dev set upgrade for some protocolVersion
    /// @param _cutData the new diamond cut data
    /// @param _oldProtocolVersion the old protocol version
    function setUpgradeDiamondCutInner(Diamond.DiamondCutData memory _cutData, uint256 _oldProtocolVersion) internal {
        bytes32 newCutHash = keccak256(abi.encode(_cutData));
        __DEPRECATED_upgradeCutHash[_oldProtocolVersion] = newCutHash;
        __DEPRECATED_upgradeCutDataBlock[_oldProtocolVersion] = block.number;
        emit NewUpgradeCutHash(_oldProtocolVersion, newCutHash);
        emit NewUpgradeCutData(_oldProtocolVersion, _cutData);
    }

    /// @inheritdoc IChainTypeManager
    function upgradeCutHash(uint256 _protocolVersion) public view returns (bytes32) {
        return __DEPRECATED_upgradeCutHash[_protocolVersion];
    }

    /// @dev freezes the specified chain
    /// @param _chainId the chainId of the chain
    function freezeChain(uint256 _chainId) external onlyOwner {
        IZKChain(getZKChain(_chainId)).freezeDiamond();
    }

    /// @dev unfreezes the specified chain
    /// @param _chainId the chainId of the chain
    function unfreezeChain(uint256 _chainId) external onlyOwner {
        IZKChain(getZKChain(_chainId)).unfreezeDiamond();
    }

    /// @dev reverts batches on the specified chain
    /// @param _chainId the chainId of the chain
    /// @param _newLastBatch the new last batch
    function revertBatches(uint256 _chainId, uint256 _newLastBatch) external onlyOwner {
        address zkChainAddr = getZKChain(_chainId);
        IZKChain(zkChainAddr).revertBatchesSharedBridge(zkChainAddr, _newLastBatch);
    }

    /// @notice The upgrade cut for chains departing from `_oldProtocolVersion`, derived from the
    ///         transition committed for that edge ({upgradeTransition}).
    /// @dev Nothing is stored and nothing is handed to the chain by its caller: the transition is
    ///      the only commitment, and the cut is recomputed from it here — the same derivation
    ///      {setNewVersionUpgradeFromTransition} hashed at commit time.
    function upgradeCutForVersion(uint256 _oldProtocolVersion) public view returns (Diamond.DiamondCutData memory) {
        address transition = upgradeTransition[_oldProtocolVersion];
        if (transition == address(0)) {
            revert NoCommittedUpgradeCutForVersion(_oldProtocolVersion);
        }
        return _transitionUpgradeCut(ICTMTransition(transition));
    }

    /// @dev The cut is a pure function of the transition: no facet cuts of its own, just the
    ///      engine-init pointing back at the transition.
    function _transitionUpgradeCut(ICTMTransition _transition) internal view returns (Diamond.DiamondCutData memory) {
        return
            CTMUpgradeComposer.buildUpgradeCutData(
                _transition.upgradeEngine(),
                abi.encodeCall(IDefaultUpgrade.upgradeFromTransition, (address(_transition)))
            );
    }

    /// @dev execute predefined upgrade
    /// @param _chainId the chainId of the chain
    /// @param _oldProtocolVersion the old protocol version
    function upgradeChainFromVersion(uint256 _chainId, uint256 _oldProtocolVersion) external onlyOwner {
        address chainAddress = getZKChain(_chainId);
        IZKChain(chainAddress).upgradeChainFromVersion(chainAddress, _oldProtocolVersion);
    }

    /// @dev executes upgrade on chain
    /// @param _chainId the chainId of the chain
    /// @param _diamondCut the diamond cut data
    function executeUpgrade(uint256 _chainId, Diamond.DiamondCutData calldata _diamondCut) external onlyOwner {
        IZKChain(getZKChain(_chainId)).executeUpgrade(_diamondCut);
    }

    /// @dev setPriorityTxMaxGasLimit for the specified chain
    /// @param _chainId the chainId of the chain
    /// @param _maxGasLimit the new max gas limit
    function setPriorityTxMaxGasLimit(uint256 _chainId, uint256 _maxGasLimit) external onlyOwner {
        IZKChain(getZKChain(_chainId)).setPriorityTxMaxGasLimit(_maxGasLimit);
    }

    /// @dev setTokenMultiplier for the specified chain
    /// @param _chainId the chainId of the chain
    /// @param _nominator the new nominator of the token multiplier
    /// @param _denominator the new denominator of the token multiplier
    function setTokenMultiplier(uint256 _chainId, uint128 _nominator, uint128 _denominator) external onlyOwner {
        IZKChain(getZKChain(_chainId)).setTokenMultiplier(_nominator, _denominator);
    }

    /// @dev changeFeeParams for the specified chain
    /// @param _chainId the chainId of the chain
    /// @param _newFeeParams the new fee params
    function changeFeeParams(uint256 _chainId, FeeParams calldata _newFeeParams) external onlyOwner {
        IZKChain(getZKChain(_chainId)).changeFeeParams(_newFeeParams);
    }

    /// @dev setValidator for the specified chain
    /// @param _chainId the chainId of the chain
    /// @param _validator the new validator
    /// @param _active whether the validator is active
    function setValidator(uint256 _chainId, address _validator, bool _active) external onlyOwner {
        IZKChain(getZKChain(_chainId)).setValidator(_validator, _active);
    }

    /// @dev setPorterAvailability for the specified chain
    /// @param _chainId the chainId of the chain
    /// @param _zkPorterIsAvailable whether the zkPorter mode is available
    function setPorterAvailability(uint256 _chainId, bool _zkPorterIsAvailable) external onlyOwner {
        IZKChain(getZKChain(_chainId)).setPorterAvailability(_zkPorterIsAvailable);
    }

    /// @notice Deactivates Priority Mode for the specified chain.
    /// The chain will return to normal operation with whitelisted validators.
    /// @param _chainId the chainId of the chain
    function deactivatePriorityMode(uint256 _chainId) external onlyOwner {
        IZKChain(getZKChain(_chainId)).deactivatePriorityMode();
    }

    /// @notice deploys a full set of chains contracts
    /// @param _chainId the chain's id
    /// @param _admin the chain's admin address
    /// @dev The genesis cut is built entirely from the genesis registry this CTM pins: no facet
    ///      cuts, the DiamondInit address read from the registry, and `initialize(chainId, admin)`
    ///      as init calldata. DiamondInit reads everything else back from this CTM (it is
    ///      `msg.sender` during the proxy construction) and the registry / bridgehub.
    function _deployNewChain(uint256 _chainId, address _admin) internal returns (address zkChainAddress) {
        if (getZKChain(_chainId) != address(0)) {
            // ZKChain already registered
            revert ChainAlreadyLive();
        }

        address diamondInit = ICTMRelease(currentRelease).diamondInit();
        Diamond.DiamondCutData memory diamondCut = Diamond.DiamondCutData({
            facetCuts: new Diamond.FacetCut[](0),
            initAddress: diamondInit,
            initCalldata: abi.encodeCall(IDiamondInit.initialize, (_chainId, _admin))
        });
        // deploy zkChainContract
        // slither-disable-next-line reentrancy-no-eth
        DiamondProxy zkChainContract = new DiamondProxy{salt: bytes32(0)}(block.chainid, diamondCut);
        // save data
        zkChainAddress = address(zkChainContract);
        emit NewZKChain(_chainId, zkChainAddress);
    }

    /// @notice called by Bridgehub when a chain registers
    /// @param _chainId the chain's id
    /// @param _admin the chain's admin address
    /// @dev The bridgehub passes only the minimal chain-specific data. The base token asset id is
    /// read by DiamondInit from the bridgehub (which registers it before this call), and the
    /// genesis force-deployments (with their factory-dep hashes) live in the registry, so neither
    /// is forwarded. Genesis factory-dep bytecodes are published out-of-band (via the bytecodes
    /// supplier) and referenced by hash, so an empty `_factoryDeps` is passed to `genesisUpgrade`.
    function createNewChain(uint256 _chainId, address _admin) external onlyBridgehub returns (address zkChainAddress) {
        zkChainAddress = _deployNewChain(_chainId, _admin);

        // genesis upgrade, deploys some contracts, sets chainId. The force-deployments data and
        // the genesis-upgrade address are read from the registry (single source of truth).
        bytes memory forceDeploymentsData = ICTMRelease(currentRelease).fixedForceDeploymentsData();
        IAdmin(zkChainAddress).genesisUpgrade(
            l1GenesisUpgrade(),
            address(IL1Bridgehub(BRIDGE_HUB).l1CtmDeployer()),
            forceDeploymentsData,
            new bytes[](0)
        );
        // Deposits start paused by default to allow immediate Gateway migration.
        // Otherwise, any deposit would trigger the PAUSE_DEPOSITS_TIME_WINDOW_START delay.
        IMigrator(zkChainAddress).pauseDepositsBeforeInitiatingMigration();
    }

    /// @param _chainId the chainId of the chain
    function getProtocolVersion(uint256 _chainId) public view returns (uint256) {
        return IZKChain(getZKChain(_chainId)).getProtocolVersion();
    }

    /// @notice Called by the bridgehub during the migration of a chain to another settlement layer.
    /// @param _chainId The chain id of the chain to be migrated.
    /// @param _data The data needed to perform the migration.
    function forwardedBridgeBurn(
        uint256 _chainId,
        bytes calldata _data
    ) external view override onlyChainAssetHandler returns (bytes memory ctmForwardedBridgeMintData) {
        // The destination CTM rebuilds the genesis cut from its own registry, so no cut is
        // forwarded — only the new admin. The base token asset id is re-registered on the
        // destination bridgehub before its `forwardedBridgeMint`, so it isn't forwarded either.
        address _newSettlementLayerAdmin = abi.decode(_data, (address));
        if (_newSettlementLayerAdmin == address(0)) {
            revert AdminZero();
        }

        // We ensure that the chain has the latest protocol version to avoid edge cases
        // related to different protocol version support.
        uint256 chainProtocolVersion = IZKChain(getZKChain(_chainId)).getProtocolVersion();
        if (chainProtocolVersion != protocolVersion) {
            revert OutdatedProtocolVersion(protocolVersion, chainProtocolVersion);
        }

        return abi.encode(_newSettlementLayerAdmin, protocolVersion);
    }

    /// @notice Called by the bridgehub during the migration of a chain to the current settlement layer.
    /// @param _chainId The chain id of the chain to be migrated.
    /// @param _ctmData The data returned from `forwardedBridgeBurn` for the chain.
    function forwardedBridgeMint(
        uint256 _chainId,
        bytes calldata _ctmData
    ) external override onlyChainAssetHandler returns (address chainAddress) {
        (address _admin, uint256 _protocolVersion) = abi.decode(_ctmData, (address, uint256));

        // We ensure that the chain has the latest protocol version to avoid edge cases
        // related to different protocol version support.
        if (_protocolVersion != protocolVersion) {
            revert OutdatedProtocolVersion(protocolVersion, _protocolVersion);
        }
        chainAddress = _deployNewChain({_chainId: _chainId, _admin: _admin});
    }

    /// @notice Called by the bridgehub during the failed migration of a chain.
    /// param _chainId the chainId of the chain
    /// param _assetInfo the assetInfo of the chain
    /// param _depositSender the address of that sent the deposit
    /// param _ctmData the data of the migration
    function forwardedBridgeConfirmTransferResult(
        uint256 /* _chainId */,
        TxStatus /* _txStatus */,
        bytes32 /* _assetInfo */,
        address /* _depositSender */,
        bytes calldata /* _ctmData */
    ) external onlyChainAssetHandler {
        // Function is empty due to the fact that when calling `forwardedBridgeBurn` there are no
        // state updates that occur.
    }

    /*//////////////////////////////////////////////////////////////
                            Legacy functions
    //////////////////////////////////////////////////////////////*/

    /// @notice return the chain contract address for a chainId
    function getHyperchain(uint256 _chainId) public view returns (address) {
        // During upgrade, there will be a period when the zkChains mapping on
        // bridgehub will not be filled yet, while the ValidatorTimelock
        // will still query the address to obtain the chain id.
        //
        // To cover this case, we firstly use the existing storage and only then
        // we use the bridgehub if the former was not present.
        // This logic should be deleted in one of the future upgrades.
        address legacyAddress = getZKChainLegacy(_chainId);
        if (legacyAddress != address(0)) {
            return legacyAddress;
        }
        return getZKChain(_chainId);
    }

    /// @notice Returns the legacy validator timelock address.
    /// @dev This function is used to return the validator timelock address for pre-v29 protocol versions.
    /// @dev This function is deprecated and will be removed in the future.
    function validatorTimelock() external view returns (address) {
        return __DEPRECATED_validatorTimelock;
    }
}
