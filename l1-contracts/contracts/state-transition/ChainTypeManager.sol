// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {EnumerableMap} from "@openzeppelin/contracts-v4/utils/structs/EnumerableMap.sol";
import {SafeCast} from "@openzeppelin/contracts-v4/utils/math/SafeCast.sol";

import {Diamond} from "./libraries/Diamond.sol";
import {DiamondProxy} from "./chain-deps/DiamondProxy.sol";
import {IAdmin} from "./chain-interfaces/IAdmin.sol";
import {IDiamondInit} from "./chain-interfaces/IDiamondInit.sol";
import {IExecutor} from "./chain-interfaces/IExecutor.sol";
import {IChainTypeManager, ChainTypeManagerInitializeData, ChainCreationParams} from "./IChainTypeManager.sol";
import {IZKChain} from "./chain-interfaces/IZKChain.sol";
import {FeeParams} from "./chain-deps/ZKChainStorage.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {L2_TO_L1_LOG_SERIALIZE_SIZE, DEFAULT_L2_LOGS_TREE_ROOT_HASH, EMPTY_STRING_KECCAK} from "../common/Config.sol";
import {InitialForceDeploymentMismatch, AdminZero, OutdatedProtocolVersion} from "./L1StateTransitionErrors.sol";
import {ChainAlreadyLive, Unauthorized, ZeroAddress, HashMismatch, GenesisUpgradeZero, GenesisBatchHashZero, GenesisIndexStorageZero, GenesisBatchCommitmentZero, MigrationsNotPaused} from "../common/L1ContractErrors.sol";
import {SemVer} from "../common/libraries/SemVer.sol";
import {IBridgehub} from "../bridgehub/IBridgehub.sol";

import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";

/// @title Chain Type Manager contract
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract ChainTypeManager is IChainTypeManager, ReentrancyGuard, Ownable2StepUpgradeable {
    using EnumerableMap for EnumerableMap.UintToAddressMap;

    /// @notice Address of the bridgehub
    address public immutable BRIDGE_HUB;

    /// @notice The map from chainId => zkChain contract
    EnumerableMap.UintToAddressMap internal __DEPRECATED_zkChainMap;

    /// @dev The batch zero hash, calculated at initialization
    bytes32 public storedBatchZero;

    /// @dev The stored cutData for diamond cut
    bytes32 public initialCutHash;

    /// @dev The l1GenesisUpgrade contract address, used to set chainId
    address public l1GenesisUpgrade;

    /// @dev The current packed protocolVersion. To access human-readable version, use `getSemverProtocolVersion` function.
    uint256 public protocolVersion;

    /// @dev The timestamp when protocolVersion can be last used
    mapping(uint256 _protocolVersion => uint256) public protocolVersionDeadline;

    /// @dev The validatorTimelock contract address
    address public validatorTimelock;

    /// @dev The stored cutData for upgrade diamond cut. protocolVersion => cutHash
    mapping(uint256 protocolVersion => bytes32 cutHash) public upgradeCutHash;

    /// @dev The address used to manage non critical updates
    address public admin;

    /// @dev The address to accept the admin role
    address private pendingAdmin;

    /// @dev The initial force deployment hash
    bytes32 public initialForceDeploymentHash;

    /// @dev The contract, that notifies server about l1 changes
    address public serverNotifierAddress;

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    /// @dev Note, that while the contract does not use `nonReentrant` modifier, we still keep the `reentrancyGuardInitializer`
    /// here for two reasons:
    /// - It prevents the function from being called twice (including in the proxy impl).
    /// - It makes the local version consistent with the one in production, which already had the reentrancy guard
    /// initialized.
    constructor(address _bridgehub) reentrancyGuardInitializer {
        BRIDGE_HUB = _bridgehub;

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

    /// @return The tuple of (major, minor, patch) protocol version.
    function getSemverProtocolVersion() external view returns (uint32, uint32, uint32) {
        // slither-disable-next-line unused-return
        return SemVer.unpackSemVer(SafeCast.toUint96(protocolVersion));
    }

    /// @notice return the chain contract address for a chainId
    function getZKChain(uint256 _chainId) public view returns (address) {
        return IBridgehub(BRIDGE_HUB).getZKChain(_chainId);
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
        _transferOwnership(_initializeData.owner);

        protocolVersion = _initializeData.protocolVersion;
        _setProtocolVersionDeadline(_initializeData.protocolVersion, type(uint256).max);
        validatorTimelock = _initializeData.validatorTimelock;
        serverNotifierAddress = _initializeData.serverNotifier;

        _setChainCreationParams(_initializeData.chainCreationParams);
    }

    /// @notice Updates the parameters with which a new chain is created
    /// @param _chainCreationParams The new chain creation parameters
    function _setChainCreationParams(ChainCreationParams calldata _chainCreationParams) internal {
        if (_chainCreationParams.genesisUpgrade == address(0)) {
            revert GenesisUpgradeZero();
        }
        if (_chainCreationParams.genesisBatchHash == bytes32(0)) {
            revert GenesisBatchHashZero();
        }
        if (_chainCreationParams.genesisIndexRepeatedStorageChanges == uint64(0)) {
            revert GenesisIndexStorageZero();
        }
        if (_chainCreationParams.genesisBatchCommitment == bytes32(0)) {
            revert GenesisBatchCommitmentZero();
        }

        l1GenesisUpgrade = _chainCreationParams.genesisUpgrade;

        // We need to initialize the state hash because it is used in the commitment of the next batch
        IExecutor.StoredBatchInfo memory batchZero = IExecutor.StoredBatchInfo({
            batchNumber: 0,
            batchHash: _chainCreationParams.genesisBatchHash,
            indexRepeatedStorageChanges: _chainCreationParams.genesisIndexRepeatedStorageChanges,
            numberOfLayer1Txs: 0,
            priorityOperationsHash: EMPTY_STRING_KECCAK,
            l2LogsTreeRoot: DEFAULT_L2_LOGS_TREE_ROOT_HASH,
            timestamp: 0,
            commitment: _chainCreationParams.genesisBatchCommitment
        });
        storedBatchZero = keccak256(abi.encode(batchZero));
        bytes32 newInitialCutHash = keccak256(abi.encode(_chainCreationParams.diamondCut));
        initialCutHash = newInitialCutHash;
        bytes32 forceDeploymentHash = keccak256(abi.encode(_chainCreationParams.forceDeploymentsData));
        initialForceDeploymentHash = forceDeploymentHash;

        emit NewChainCreationParams({
            genesisUpgrade: _chainCreationParams.genesisUpgrade,
            genesisBatchHash: _chainCreationParams.genesisBatchHash,
            genesisIndexRepeatedStorageChanges: _chainCreationParams.genesisIndexRepeatedStorageChanges,
            genesisBatchCommitment: _chainCreationParams.genesisBatchCommitment,
            newInitialCutHash: newInitialCutHash,
            forceDeploymentHash: forceDeploymentHash
        });
    }

    /// @notice Updates the parameters with which a new chain is created
    /// @param _chainCreationParams The new chain creation parameters
    function setChainCreationParams(ChainCreationParams calldata _chainCreationParams) external onlyOwner {
        _setChainCreationParams(_chainCreationParams);
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
        address currentPendingAdmin = pendingAdmin;
        // Only proposed by current admin address can claim the admin rights
        if (msg.sender != currentPendingAdmin) {
            revert Unauthorized(msg.sender);
        }

        address previousAdmin = admin;
        admin = currentPendingAdmin;
        delete pendingAdmin;

        emit NewPendingAdmin(currentPendingAdmin, address(0));
        emit NewAdmin(previousAdmin, currentPendingAdmin);
    }

    /// @dev set validatorTimelock. Cannot do it during initialization, as validatorTimelock is deployed after CTM
    /// @param _validatorTimelock the new validatorTimelock address
    function setValidatorTimelock(address _validatorTimelock) external onlyOwner {
        address oldValidatorTimelock = validatorTimelock;
        validatorTimelock = _validatorTimelock;
        emit NewValidatorTimelock(oldValidatorTimelock, _validatorTimelock);
    }

    /// @dev set ServerNotifier.
    /// @param _serverNotifier the new serverNotifier address
    function setServerNotifier(address _serverNotifier) external onlyOwnerOrAdmin {
        address oldServerNotifier = serverNotifierAddress;
        serverNotifierAddress = _serverNotifier;
        emit NewServerNotifier(oldServerNotifier, _serverNotifier);
    }

    /// @dev set New Version with upgrade from old version
    /// @param _cutData the new diamond cut data
    /// @param _oldProtocolVersion the old protocol version
    /// @param _oldProtocolVersionDeadline the deadline for the old protocol version
    /// @param _newProtocolVersion the new protocol version
    function setNewVersionUpgrade(
        Diamond.DiamondCutData calldata _cutData,
        uint256 _oldProtocolVersion,
        uint256 _oldProtocolVersionDeadline,
        uint256 _newProtocolVersion
    ) external onlyOwner {
        if (!IBridgehub(BRIDGE_HUB).migrationPaused()) {
            revert MigrationsNotPaused();
        }

        bytes32 newCutHash = keccak256(abi.encode(_cutData));
        uint256 previousProtocolVersion = protocolVersion;
        upgradeCutHash[_oldProtocolVersion] = newCutHash;
        _setProtocolVersionDeadline(_oldProtocolVersion, _oldProtocolVersionDeadline);
        _setProtocolVersionDeadline(_newProtocolVersion, type(uint256).max);
        protocolVersion = _newProtocolVersion;
        emit NewProtocolVersion(previousProtocolVersion, _newProtocolVersion);
        emit NewUpgradeCutHash(_oldProtocolVersion, newCutHash);
        emit NewUpgradeCutData(_newProtocolVersion, _cutData);
    }

    /// @dev check that the protocolVersion is active
    /// @param _protocolVersion the protocol version to check
    function protocolVersionIsActive(uint256 _protocolVersion) external view override returns (bool) {
        return block.timestamp <= protocolVersionDeadline[_protocolVersion];
    }

    /// @notice Set the protocol version deadline
    /// @param _protocolVersion the protocol version
    /// @param _timestamp the timestamp is the deadline
    function setProtocolVersionDeadline(uint256 _protocolVersion, uint256 _timestamp) external onlyOwner {
        _setProtocolVersionDeadline(_protocolVersion, _timestamp);
    }

    /// @dev set upgrade for some protocolVersion
    /// @param _cutData the new diamond cut data
    /// @param _oldProtocolVersion the old protocol version
    function setUpgradeDiamondCut(
        Diamond.DiamondCutData calldata _cutData,
        uint256 _oldProtocolVersion
    ) external onlyOwner {
        bytes32 newCutHash = keccak256(abi.encode(_cutData));
        upgradeCutHash[_oldProtocolVersion] = newCutHash;
        emit NewUpgradeCutHash(_oldProtocolVersion, newCutHash);
    }

    /// @dev freezes the specified chain
    /// @param _chainId the chainId of the chain
    function freezeChain(uint256 _chainId) external onlyOwner {
        IZKChain(getZKChain(_chainId)).freezeDiamond();
    }

    /// @dev freezes the specified chain
    /// @param _chainId the chainId of the chain
    function unfreezeChain(uint256 _chainId) external onlyOwner {
        IZKChain(getZKChain(_chainId)).unfreezeDiamond();
    }

    /// @dev reverts batches on the specified chain
    /// @param _chainId the chainId of the chain
    /// @param _newLastBatch the new last batch
    function revertBatches(uint256 _chainId, uint256 _newLastBatch) external onlyOwnerOrAdmin {
        IZKChain(getZKChain(_chainId)).revertBatchesSharedBridge(_chainId, _newLastBatch);
    }

    /// @dev execute predefined upgrade
    /// @param _chainId the chainId of the chain
    /// @param _oldProtocolVersion the old protocol version
    /// @param _diamondCut the diamond cut data
    function upgradeChainFromVersion(
        uint256 _chainId,
        uint256 _oldProtocolVersion,
        Diamond.DiamondCutData calldata _diamondCut
    ) external onlyOwner {
        IZKChain(getZKChain(_chainId)).upgradeChainFromVersion(_oldProtocolVersion, _diamondCut);
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

    /// registration

    /// @notice deploys a full set of chains contracts
    /// @param _chainId the chain's id
    /// @param _baseTokenAssetId the base token asset id used to pay for gas fees
    /// @param _admin the chain's admin address
    /// @param _diamondCut the diamond cut data that initializes the chains Diamond Proxy
    function _deployNewChain(
        uint256 _chainId,
        bytes32 _baseTokenAssetId,
        address _admin,
        bytes memory _diamondCut
    ) internal returns (address zkChainAddress) {
        if (getZKChain(_chainId) != address(0)) {
            // ZKChain already registered
            revert ChainAlreadyLive();
        }

        Diamond.DiamondCutData memory diamondCut = abi.decode(_diamondCut, (Diamond.DiamondCutData));

        {
            // check input
            bytes32 cutHashInput = keccak256(_diamondCut);
            if (cutHashInput != initialCutHash) {
                revert HashMismatch(initialCutHash, cutHashInput);
            }
        }

        // construct init data
        bytes memory initData;
        /// all together 4+9*32=292 bytes for the selector + mandatory data
        // solhint-disable-next-line func-named-parameters
        initData = bytes.concat(
            IDiamondInit.initialize.selector,
            bytes32(_chainId),
            bytes32(uint256(uint160(BRIDGE_HUB))),
            bytes32(uint256(uint160(address(this)))),
            bytes32(protocolVersion),
            bytes32(uint256(uint160(_admin))),
            bytes32(uint256(uint160(validatorTimelock))),
            _baseTokenAssetId,
            storedBatchZero,
            diamondCut.initCalldata
        );

        diamondCut.initCalldata = initData;
        // deploy zkChainContract
        // slither-disable-next-line reentrancy-no-eth
        DiamondProxy zkChainContract = new DiamondProxy{salt: bytes32(0)}(block.chainid, diamondCut);
        // save data
        zkChainAddress = address(zkChainContract);
        emit NewZKChain(_chainId, zkChainAddress);
    }

    /// @notice called by Bridgehub when a chain registers
    /// @param _chainId the chain's id
    /// @param _baseTokenAssetId the base token asset id used to pay for gas fees
    /// @param _admin the chain's admin address
    /// @param _initData the diamond cut data, force deployments and factoryDeps encoded
    /// @param _factoryDeps the factory dependencies used for the genesis upgrade
    /// that initializes the chains Diamond Proxy
    function createNewChain(
        uint256 _chainId,
        bytes32 _baseTokenAssetId,
        address _admin,
        bytes calldata _initData,
        bytes[] calldata _factoryDeps
    ) external onlyBridgehub returns (address zkChainAddress) {
        (bytes memory _diamondCut, bytes memory _forceDeploymentData) = abi.decode(_initData, (bytes, bytes));

        // solhint-disable-next-line func-named-parameters
        zkChainAddress = _deployNewChain(_chainId, _baseTokenAssetId, _admin, _diamondCut);

        {
            // check input
            bytes32 forceDeploymentHash = keccak256(abi.encode(_forceDeploymentData));
            if (forceDeploymentHash != initialForceDeploymentHash) {
                revert InitialForceDeploymentMismatch(forceDeploymentHash, initialForceDeploymentHash);
            }
        }
        // genesis upgrade, deploys some contracts, sets chainId
        IAdmin(zkChainAddress).genesisUpgrade(
            l1GenesisUpgrade,
            address(IBridgehub(BRIDGE_HUB).l1CtmDeployer()),
            _forceDeploymentData,
            _factoryDeps
        );
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
    ) external view override onlyBridgehub returns (bytes memory ctmForwardedBridgeMintData) {
        // Note that the `_diamondCut` here is not for the current chain, for the chain where the migration
        // happens. The correctness of it will be checked on the CTM on the new settlement layer.
        (address _newSettlementLayerAdmin, bytes memory _diamondCut) = abi.decode(_data, (address, bytes));
        if (_newSettlementLayerAdmin == address(0)) {
            revert AdminZero();
        }

        // We ensure that the chain has the latest protocol version to avoid edge cases
        // related to different protocol version support.
        uint256 chainProtocolVersion = IZKChain(getZKChain(_chainId)).getProtocolVersion();
        if (chainProtocolVersion != protocolVersion) {
            revert OutdatedProtocolVersion(chainProtocolVersion, protocolVersion);
        }

        return
            abi.encode(
                IBridgehub(BRIDGE_HUB).baseTokenAssetId(_chainId),
                _newSettlementLayerAdmin,
                protocolVersion,
                _diamondCut
            );
    }

    /// @notice Called by the bridgehub during the migration of a chain to the current settlement layer.
    /// @param _chainId The chain id of the chain to be migrated.
    /// @param _ctmData The data returned from `forwardedBridgeBurn` for the chain.
    function forwardedBridgeMint(
        uint256 _chainId,
        bytes calldata _ctmData
    ) external override onlyBridgehub returns (address chainAddress) {
        (bytes32 _baseTokenAssetId, address _admin, uint256 _protocolVersion, bytes memory _diamondCut) = abi.decode(
            _ctmData,
            (bytes32, address, uint256, bytes)
        );

        // We ensure that the chain has the latest protocol version to avoid edge cases
        // related to different protocol version support.
        if (_protocolVersion != protocolVersion) {
            revert OutdatedProtocolVersion(_protocolVersion, protocolVersion);
        }
        chainAddress = _deployNewChain({
            _chainId: _chainId,
            _baseTokenAssetId: _baseTokenAssetId,
            _admin: _admin,
            _diamondCut: _diamondCut
        });
    }

    /// @notice Called by the bridgehub during the failed migration of a chain.
    /// param _chainId the chainId of the chain
    /// param _assetInfo the assetInfo of the chain
    /// param _depositSender the address of that sent the deposit
    /// param _ctmData the data of the migration
    function forwardedBridgeRecoverFailedTransfer(
        uint256 /* _chainId */,
        bytes32 /* _assetInfo */,
        address /* _depositSender */,
        bytes calldata /* _ctmData */
    ) external {
        // Function is empty due to the fact that when calling `forwardedBridgeBurn` there are no
        // state updates that occur.
    }

    /// @notice Set the protocol version deadline
    /// @param _protocolVersion the protocol version
    /// @param _timestamp the timestamp is the deadline
    function _setProtocolVersionDeadline(uint256 _protocolVersion, uint256 _timestamp) internal {
        protocolVersionDeadline[_protocolVersion] = _timestamp;
        emit UpdateProtocolVersionDeadline(_protocolVersion, _timestamp);
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
}
