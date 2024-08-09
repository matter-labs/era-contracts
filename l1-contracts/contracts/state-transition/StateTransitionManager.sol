// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// solhint-disable gas-custom-errors, reason-string

import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {Diamond} from "./libraries/Diamond.sol";
import {DiamondProxy} from "./chain-deps/DiamondProxy.sol";
import {IAdmin} from "./chain-interfaces/IAdmin.sol";
import {IDiamondInit} from "./chain-interfaces/IDiamondInit.sol";
import {IExecutor} from "./chain-interfaces/IExecutor.sol";
import {IStateTransitionManager, StateTransitionManagerInitializeData, ChainCreationParams} from "./IStateTransitionManager.sol";
import {IZkSyncHyperchain} from "./chain-interfaces/IZkSyncHyperchain.sol";
import {FeeParams} from "./chain-deps/ZkSyncHyperchainStorage.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {L2_TO_L1_LOG_SERIALIZE_SIZE, DEFAULT_L2_LOGS_TREE_ROOT_HASH, EMPTY_STRING_KECCAK} from "../common/Config.sol";
import {SemVer} from "../common/libraries/SemVer.sol";
import {IBridgehub} from "../bridgehub/IBridgehub.sol";

/// @title State Transition Manager contract
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract StateTransitionManager is IStateTransitionManager, ReentrancyGuard, Ownable2StepUpgradeable {
    using EnumerableMap for EnumerableMap.UintToAddressMap;

    /// @notice Address of the bridgehub
    address public immutable BRIDGE_HUB;

    /// @notice The total number of hyperchains can be created/connected to this STM.
    /// This is the temporary security measure.
    uint256 public immutable MAX_NUMBER_OF_HYPERCHAINS;

    /// @notice The map from chainId => hyperchain contract
    EnumerableMap.UintToAddressMap internal hyperchainMap;

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

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(address _bridgehub, uint256 _maxNumberOfHyperchains) reentrancyGuardInitializer {
        BRIDGE_HUB = _bridgehub;
        MAX_NUMBER_OF_HYPERCHAINS = _maxNumberOfHyperchains;

        // While this does not provide a protection in the production, it is needed for local testing
        // Length of the L2Log encoding should not be equal to the length of other L2Logs' tree nodes preimages
        assert(L2_TO_L1_LOG_SERIALIZE_SIZE != 2 * 32);
    }

    /// @notice only the bridgehub can call
    modifier onlyBridgehub() {
        require(msg.sender == BRIDGE_HUB, "STM: only bridgehub");
        _;
    }

    /// @notice the admin can call, for non-critical updates
    modifier onlyOwnerOrAdmin() {
        require(msg.sender == admin || msg.sender == owner(), "STM: not owner or admin");
        _;
    }

    /// @return The tuple of (major, minor, patch) protocol version.
    function getSemverProtocolVersion() external view returns (uint32, uint32, uint32) {
        // slither-disable-next-line unused-return
        return SemVer.unpackSemVer(SafeCast.toUint96(protocolVersion));
    }

    /// @notice Returns all the registered hyperchain addresses
    function getAllHyperchains() public view override returns (address[] memory chainAddresses) {
        uint256[] memory keys = hyperchainMap.keys();
        chainAddresses = new address[](keys.length);
        uint256 keysLength = keys.length;
        for (uint256 i = 0; i < keysLength; ++i) {
            chainAddresses[i] = hyperchainMap.get(keys[i]);
        }
    }

    /// @notice Returns all the registered hyperchain chainIDs
    function getAllHyperchainChainIDs() public view override returns (uint256[] memory) {
        return hyperchainMap.keys();
    }

    /// @notice Returns the address of the hyperchain with the corresponding chainID
    /// @param _chainId the chainId of the chain
    /// @return chainAddress the address of the hyperchain
    function getHyperchain(uint256 _chainId) public view override returns (address chainAddress) {
        // slither-disable-next-line unused-return
        (, chainAddress) = hyperchainMap.tryGet(_chainId);
    }

    /// @notice Returns the address of the hyperchain admin with the corresponding chainID
    /// @param _chainId the chainId of the chain
    function getChainAdmin(uint256 _chainId) external view override returns (address) {
        return IZkSyncHyperchain(hyperchainMap.get(_chainId)).getAdmin();
    }

    /// @dev initialize
    function initialize(
        StateTransitionManagerInitializeData calldata _initializeData
    ) external reentrancyGuardInitializer {
        require(_initializeData.owner != address(0), "STM: owner zero");
        _transferOwnership(_initializeData.owner);

        protocolVersion = _initializeData.protocolVersion;
        protocolVersionDeadline[_initializeData.protocolVersion] = type(uint256).max;
        validatorTimelock = _initializeData.validatorTimelock;

        _setChainCreationParams(_initializeData.chainCreationParams);
    }

    /// @notice Updates the parameters with which a new chain is created
    /// @param _chainCreationParams The new chain creation parameters
    function _setChainCreationParams(ChainCreationParams calldata _chainCreationParams) internal {
        require(_chainCreationParams.genesisUpgrade != address(0), "STM: genesisUpgrade zero");
        require(_chainCreationParams.genesisBatchHash != bytes32(0), "STM: genesisBatchHash zero");
        require(
            _chainCreationParams.genesisIndexRepeatedStorageChanges != uint64(0),
            "STM: genesisIndexRepeatedStorageChanges zero"
        );
        require(_chainCreationParams.genesisBatchCommitment != bytes32(0), "STM: genesisBatchCommitment zero");

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
        require(msg.sender == currentPendingAdmin, "n42"); // Only proposed by current admin address can claim the admin rights

        address previousAdmin = admin;
        admin = currentPendingAdmin;
        delete pendingAdmin;

        emit NewPendingAdmin(currentPendingAdmin, address(0));
        emit NewAdmin(previousAdmin, currentPendingAdmin);
    }

    /// @dev set validatorTimelock. Cannot do it during initialization, as validatorTimelock is deployed after STM
    /// @param _validatorTimelock the new validatorTimelock address
    function setValidatorTimelock(address _validatorTimelock) external onlyOwnerOrAdmin {
        address oldValidatorTimelock = validatorTimelock;
        validatorTimelock = _validatorTimelock;
        emit NewValidatorTimelock(oldValidatorTimelock, _validatorTimelock);
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
        bytes32 newCutHash = keccak256(abi.encode(_cutData));
        uint256 previousProtocolVersion = protocolVersion;
        upgradeCutHash[_oldProtocolVersion] = newCutHash;
        protocolVersionDeadline[_oldProtocolVersion] = _oldProtocolVersionDeadline;
        protocolVersionDeadline[_newProtocolVersion] = type(uint256).max;
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

    /// @dev set the protocol version timestamp
    /// @param _protocolVersion the protocol version
    /// @param _timestamp the timestamp is the deadline
    function setProtocolVersionDeadline(uint256 _protocolVersion, uint256 _timestamp) external onlyOwner {
        protocolVersionDeadline[_protocolVersion] = _timestamp;
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
        IZkSyncHyperchain(hyperchainMap.get(_chainId)).freezeDiamond();
    }

    /// @dev freezes the specified chain
    /// @param _chainId the chainId of the chain
    function unfreezeChain(uint256 _chainId) external onlyOwner {
        IZkSyncHyperchain(hyperchainMap.get(_chainId)).unfreezeDiamond();
    }

    /// @dev reverts batches on the specified chain
    /// @param _chainId the chainId of the chain
    /// @param _newLastBatch the new last batch
    function revertBatches(uint256 _chainId, uint256 _newLastBatch) external onlyOwnerOrAdmin {
        IZkSyncHyperchain(hyperchainMap.get(_chainId)).revertBatches(_newLastBatch);
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
        IZkSyncHyperchain(hyperchainMap.get(_chainId)).upgradeChainFromVersion(_oldProtocolVersion, _diamondCut);
    }

    /// @dev executes upgrade on chain
    /// @param _chainId the chainId of the chain
    /// @param _diamondCut the diamond cut data
    function executeUpgrade(uint256 _chainId, Diamond.DiamondCutData calldata _diamondCut) external onlyOwner {
        IZkSyncHyperchain(hyperchainMap.get(_chainId)).executeUpgrade(_diamondCut);
    }

    /// @dev setPriorityTxMaxGasLimit for the specified chain
    /// @param _chainId the chainId of the chain
    /// @param _maxGasLimit the new max gas limit
    function setPriorityTxMaxGasLimit(uint256 _chainId, uint256 _maxGasLimit) external onlyOwner {
        IZkSyncHyperchain(hyperchainMap.get(_chainId)).setPriorityTxMaxGasLimit(_maxGasLimit);
    }

    /// @dev setTokenMultiplier for the specified chain
    /// @param _chainId the chainId of the chain
    /// @param _nominator the new nominator of the token multiplier
    /// @param _denominator the new denominator of the token multiplier
    function setTokenMultiplier(uint256 _chainId, uint128 _nominator, uint128 _denominator) external onlyOwner {
        IZkSyncHyperchain(hyperchainMap.get(_chainId)).setTokenMultiplier(_nominator, _denominator);
    }

    /// @dev changeFeeParams for the specified chain
    /// @param _chainId the chainId of the chain
    /// @param _newFeeParams the new fee params
    function changeFeeParams(uint256 _chainId, FeeParams calldata _newFeeParams) external onlyOwner {
        IZkSyncHyperchain(hyperchainMap.get(_chainId)).changeFeeParams(_newFeeParams);
    }

    /// @dev setValidator for the specified chain
    /// @param _chainId the chainId of the chain
    /// @param _validator the new validator
    /// @param _active whether the validator is active
    function setValidator(uint256 _chainId, address _validator, bool _active) external onlyOwnerOrAdmin {
        IZkSyncHyperchain(hyperchainMap.get(_chainId)).setValidator(_validator, _active);
    }

    /// @dev setPorterAvailability for the specified chain
    /// @param _chainId the chainId of the chain
    /// @param _zkPorterIsAvailable whether the zkPorter mode is available
    function setPorterAvailability(uint256 _chainId, bool _zkPorterIsAvailable) external onlyOwner {
        IZkSyncHyperchain(hyperchainMap.get(_chainId)).setPorterAvailability(_zkPorterIsAvailable);
    }

    /// registration

    /// @dev used to register already deployed hyperchain contracts
    /// @param _chainId the chain's id
    /// @param _hyperchain the chain's contract address
    function registerAlreadyDeployedHyperchain(uint256 _chainId, address _hyperchain) external onlyOwner {
        require(_hyperchain != address(0), "STM: hyperchain zero");

        _registerNewHyperchain(_chainId, _hyperchain);
    }

    /// @dev deploys a full set of chains contracts
    function _deployNewChain(
        uint256 _chainId,
        address _baseToken,
        address _sharedBridge,
        address _admin,
        bytes memory _diamondCut
    ) internal returns (address hyperchainAddress) {
        if (getHyperchain(_chainId) != address(0)) {
            // Hyperchain already registered
            return getHyperchain(_chainId);
        }

        // check not registered
        Diamond.DiamondCutData memory diamondCut = abi.decode(_diamondCut, (Diamond.DiamondCutData));

        {
            // check input
            bytes32 cutHashInput = keccak256(_diamondCut);
            require(cutHashInput == initialCutHash, "STM: initial cutHash mismatch");
        }
        bytes memory mandatoryInitData;
        {
            // solhint-disable-next-line func-named-parameters
            mandatoryInitData = bytes.concat(
                bytes32(_chainId),
                bytes32(uint256(uint160(BRIDGE_HUB))),
                bytes32(uint256(uint160(address(this)))),
                bytes32(protocolVersion),
                bytes32(uint256(uint160(_admin))),
                bytes32(uint256(uint160(validatorTimelock))),
                bytes32(uint256(uint160(_baseToken))),
                bytes32(uint256(uint160(_sharedBridge))),
                storedBatchZero
            );
        }

        // construct init data
        bytes memory initData;
        /// all together 4+9*32=292 bytes for the selector + mandatory data
        // solhint-disable-next-line func-named-parameters
        initData = bytes.concat(IDiamondInit.initialize.selector, mandatoryInitData, diamondCut.initCalldata);

        diamondCut.initCalldata = initData;
        // deploy hyperchainContract
        // slither-disable-next-line reentrancy-no-eth
        DiamondProxy hyperchainContract = new DiamondProxy{salt: bytes32(0)}(block.chainid, diamondCut);
        // save data
        hyperchainAddress = address(hyperchainContract);

        _registerNewHyperchain(_chainId, hyperchainAddress);
    }

    /// @notice called by Bridgehub when a chain registers
    /// @param _chainId the chain's id
    /// @param _baseToken the base token address used to pay for gas fees
    /// @param _sharedBridge the shared bridge address, used as base token bridge
    /// @param _admin the chain's admin address
    /// @param _initData the diamond cut data, force deployments and factoryDeps encoded
    /// @param _factoryDeps the factory dependencies used for the genesis upgrade
    /// that initializes the chains Diamond Proxy
    function createNewChain(
        uint256 _chainId,
        address _baseToken,
        address _sharedBridge,
        address _admin,
        bytes calldata _initData,
        bytes[] calldata _factoryDeps
    ) external onlyBridgehub {
        (bytes memory _diamondCut, bytes memory _forceDeploymentData) = abi.decode(_initData, (bytes, bytes));
        // TODO: only allow on L1.
        // solhint-disable-next-line func-named-parameters
        address hyperchainAddress = _deployNewChain(_chainId, _baseToken, _sharedBridge, _admin, _diamondCut);

        {
            // check input
            bytes32 forceDeploymentHash = keccak256(abi.encode(_forceDeploymentData));
            require(forceDeploymentHash == initialForceDeploymentHash, "STM: initial force deployment mismatch");
        }
        // genesis upgrade, deploys some contracts, sets chainId
        IAdmin(hyperchainAddress).genesisUpgrade(l1GenesisUpgrade, _forceDeploymentData, _factoryDeps);
    }

    /// @param _chainId the chainId of the chain
    function getProtocolVersion(uint256 _chainId) public view returns (uint256) {
        return IZkSyncHyperchain(hyperchainMap.get(_chainId)).getProtocolVersion();
    }

    /// @param _newSettlementLayerChainId the chainId of the chain
    /// @param _isWhitelisted whether the chain is whitelisted
    function registerSettlementLayer(uint256 _newSettlementLayerChainId, bool _isWhitelisted) external onlyOwner {
        require(_newSettlementLayerChainId != 0, "Bad chain id");

        // Currently, we require that the sync layer is deployed by the same STM.
        address settlementLayerAddress = hyperchainMap.get(_newSettlementLayerChainId);

        // TODO: Maybe `get` already ensured its existence.
        require(settlementLayerAddress != address(0), "STM: sync layer not registered");

        IBridgehub(BRIDGE_HUB).registerSettlementLayer(_newSettlementLayerChainId, _isWhitelisted);

        // TODO: emit event
    }

    /// @notice Called by the bridgehub during the migration of a chain to another settlement layer.
    /// @param _chainId The chain id of the chain to be migrated.
    /// @param _data The data needed to perform the migration.
    function forwardedBridgeBurn(
        uint256 _chainId,
        bytes calldata _data
    ) external view override onlyBridgehub returns (bytes memory stmForwardedBridgeMintData) {
        (address _newGatewayAdmin, bytes memory _diamondCut) = abi.decode(_data, (address, bytes));
        require(_newGatewayAdmin != address(0), "STM: admin zero");
        // todo check protocol version
        return abi.encode(IBridgehub(BRIDGE_HUB).baseToken(_chainId), _newGatewayAdmin, protocolVersion, _diamondCut);
    }

    /// @notice Called by the bridgehub during the migration of a chain to the current settlement layer.
    /// @param _chainId The chain id of the chain to be migrated.
    /// @param _stmData The data returned from `forwardedBridgeBurn` for the chain.
    function forwardedBridgeMint(
        uint256 _chainId,
        bytes calldata _stmData
    ) external override onlyBridgehub returns (address chainAddress) {
        (address _baseToken, address _admin, uint256 _protocolVersion, bytes memory _diamondCut) = abi.decode(
            _stmData,
            (address, address, uint256, bytes)
        );
        require(_protocolVersion == protocolVersion, "STM, outdated pv");
        // todo porotocl version check
        chainAddress = _deployNewChain({
            _chainId: _chainId,
            _baseToken: _baseToken,
            _sharedBridge: address(IBridgehub(BRIDGE_HUB).sharedBridge()),
            _admin: _admin,
            _diamondCut: _diamondCut
        });
    }

    /// @notice Called by the bridgehub during the failed migration of a chain.
    /// @param _chainId the chainId of the chain
    /// @param _assetInfo the assetInfo of the chain
    /// @param _prevMsgSender the previous message sender
    /// @param _data the data of the migration
    function bridgeClaimFailedBurn(
        uint256 _chainId,
        bytes32 _assetInfo,
        address _prevMsgSender,
        bytes calldata _data
    ) external {
        // todo
    }

    /// @dev This internal function is used to register a new hyperchain in the system.
    function _registerNewHyperchain(uint256 _chainId, address _hyperchain) internal {
        // slither-disable-next-line unused-return
        hyperchainMap.set(_chainId, _hyperchain);
        require(hyperchainMap.length() <= MAX_NUMBER_OF_HYPERCHAINS, "STM: Hyperchain limit reached");
        emit NewHyperchain(_chainId, _hyperchain);
    }
}
