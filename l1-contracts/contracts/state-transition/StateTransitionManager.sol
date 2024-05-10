// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

import {IBridgehub, L2TransactionRequestDirect, L2TransactionRequestTwoBridgesOuter, L2TransactionRequestTwoBridgesInner} from "../bridgehub/IBridgehub.sol";

import {Diamond} from "./libraries/Diamond.sol";
import {DiamondProxy} from "./chain-deps/DiamondProxy.sol";
import {IAdmin} from "./chain-interfaces/IAdmin.sol";
import {IDefaultUpgrade} from "../upgrades/IDefaultUpgrade.sol";
import {IDiamondInit} from "./chain-interfaces/IDiamondInit.sol";
import {IExecutor} from "./chain-interfaces/IExecutor.sol";
import {IStateTransitionManager, StateTransitionManagerInitializeData} from "./IStateTransitionManager.sol";
import {ISystemContext} from "./l2-deps/ISystemContext.sol";
import {IZkSyncHyperchain} from "./chain-interfaces/IZkSyncHyperchain.sol";
import {FeeParams, SyncLayerState} from "./chain-deps/ZkSyncHyperchainStorage.sol";
import {L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR, L2_FORCE_DEPLOYER_ADDR} from "../common/L2ContractAddresses.sol";
import {L2CanonicalTransaction, TxStatus} from "../common/Messaging.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ProposedUpgrade} from "../upgrades/BaseZkSyncUpgrade.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA, L2_TO_L1_LOG_SERIALIZE_SIZE, DEFAULT_L2_LOGS_TREE_ROOT_HASH, EMPTY_STRING_KECCAK, SYSTEM_UPGRADE_L2_TX_TYPE, PRIORITY_TX_MAX_GAS_LIMIT, HyperchainCommitment} from "../common/Config.sol";
import {VerifierParams} from "./chain-interfaces/IVerifier.sol";

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

    /// @dev The genesisUpgrade contract address, used to setChainId
    address public genesisUpgrade;

    /// @dev The current protocolVersion
    uint256 public protocolVersion;

    /// @dev The timestamp when protocolVersion can be last used
    mapping(uint256 _protocolVersion => uint256) public protocolVersionDeadline;

    /// @dev The validatorTimelock contract address, used to setChainId
    address public validatorTimelock;

    /// @dev The stored cutData for upgrade diamond cut. protocolVersion => cutHash
    mapping(uint256 protocolVersion => bytes32 cutHash) public upgradeCutHash;

    /// @dev The address used to manage non critical updates
    address public admin;

    /// @dev The address to accept the admin role
    address private pendingAdmin;

    mapping(uint256 chainId => bytes32 lastMigrationTxHash) lastMigrationTxHashes;
    // mapping(uint256 chainId => bytes32 lastChainCommitment) lastMigratedCommitments;

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(address _bridgehub, uint256 _maxNumberOfHyperchains) reentrancyGuardInitializer {
        BRIDGE_HUB = _bridgehub;
        MAX_NUMBER_OF_HYPERCHAINS = _maxNumberOfHyperchains;
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

    /// @notice Returns all the registered hyperchain addresses
    function getAllHyperchains() public view override returns (address[] memory chainAddresses) {
        uint256[] memory keys = hyperchainMap.keys();
        chainAddresses = new address[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            chainAddresses[i] = hyperchainMap.get(keys[i]);
        }
    }

    /// @notice Returns all the registered hyperchain chainIDs
    function getAllHyperchainChainIDs() public view override returns (uint256[] memory) {
        return hyperchainMap.keys();
    }

    /// @notice Returns the address of the hyperchain with the corresponding chainID
    function getHyperchain(uint256 _chainId) public view override returns (address chainAddress) {
        // slither-disable-next-line unused-return
        (, chainAddress) = hyperchainMap.tryGet(_chainId);
    }

    /// @notice Returns the address of the hyperchain admin with the corresponding chainID
    function getChainAdmin(uint256 _chainId) external view override returns (address) {
        return IZkSyncHyperchain(hyperchainMap.get(_chainId)).getAdmin();
    }

    /// @dev initialize
    function initialize(
        StateTransitionManagerInitializeData calldata _initializeData
    ) external reentrancyGuardInitializer {
        require(_initializeData.owner != address(0), "STM: owner zero");
        _transferOwnership(_initializeData.owner);

        genesisUpgrade = _initializeData.genesisUpgrade;
        protocolVersion = _initializeData.protocolVersion;
        protocolVersionDeadline[_initializeData.protocolVersion] = type(uint256).max;
        validatorTimelock = _initializeData.validatorTimelock;

        // We need to initialize the state hash because it is used in the commitment of the next batch
        IExecutor.StoredBatchInfo memory batchZero = IExecutor.StoredBatchInfo({
            batchNumber: 0,
            batchHash: _initializeData.genesisBatchHash,
            indexRepeatedStorageChanges: _initializeData.genesisIndexRepeatedStorageChanges,
            numberOfLayer1Txs: 0,
            priorityOperationsHash: EMPTY_STRING_KECCAK,
            l2LogsTreeRoot: DEFAULT_L2_LOGS_TREE_ROOT_HASH,
            timestamp: 0,
            commitment: _initializeData.genesisBatchCommitment
        });
        storedBatchZero = keccak256(abi.encode(batchZero));
        initialCutHash = keccak256(abi.encode(_initializeData.diamondCut));

        // While this does not provide a protection in the production, it is needed for local testing
        // Length of the L2Log encoding should not be equal to the length of other L2Logs' tree nodes preimages
        assert(L2_TO_L1_LOG_SERIALIZE_SIZE != 2 * 32);
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
    function setValidatorTimelock(address _validatorTimelock) external onlyOwnerOrAdmin {
        address oldValidatorTimelock = validatorTimelock;
        validatorTimelock = _validatorTimelock;
        emit NewValidatorTimelock(oldValidatorTimelock, _validatorTimelock);
    }

    /// @dev set initial cutHash
    function setInitialCutHash(Diamond.DiamondCutData calldata _diamondCut) external onlyOwner {
        bytes32 oldInitialCutHash = initialCutHash;
        bytes32 newCutHash = keccak256(abi.encode(_diamondCut));
        initialCutHash = newCutHash;
        emit NewInitialCutHash(oldInitialCutHash, newCutHash);
    }

    /// @dev set New Version with upgrade from old version
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
    }

    /// @dev check that the protocolVersion is active
    function protocolVersionIsActive(uint256 _protocolVersion) public view override returns (bool) {
        return block.timestamp <= protocolVersionDeadline[_protocolVersion];
    }

    /// @dev set the protocol version timestamp
    function setProtocolVersionDeadline(uint256 _protocolVersion, uint256 _timestamp) external onlyOwner {
        protocolVersionDeadline[_protocolVersion] = _timestamp;
    }

    /// @dev set upgrade for some protocolVersion
    function setUpgradeDiamondCut(
        Diamond.DiamondCutData calldata _cutData,
        uint256 _oldProtocolVersion
    ) external onlyOwner {
        bytes32 newCutHash = keccak256(abi.encode(_cutData));
        upgradeCutHash[_oldProtocolVersion] = newCutHash;
        emit NewUpgradeCutHash(_oldProtocolVersion, newCutHash);
    }

    /// @dev freezes the specified chain
    function freezeChain(uint256 _chainId) external onlyOwner {
        IZkSyncHyperchain(hyperchainMap.get(_chainId)).freezeDiamond();
    }

    /// @dev freezes the specified chain
    function unfreezeChain(uint256 _chainId) external onlyOwner {
        IZkSyncHyperchain(hyperchainMap.get(_chainId)).unfreezeDiamond();
    }

    /// @dev reverts batches on the specified chain
    function revertBatches(uint256 _chainId, uint256 _newLastBatch) external onlyOwnerOrAdmin {
        IZkSyncHyperchain(hyperchainMap.get(_chainId)).revertBatches(_newLastBatch);
    }

    /// @dev execute predefined upgrade
    function upgradeChainFromVersion(
        uint256 _chainId,
        uint256 _oldProtocolVersion,
        Diamond.DiamondCutData calldata _diamondCut
    ) external onlyOwner {
        IZkSyncHyperchain(hyperchainMap.get(_chainId)).upgradeChainFromVersion(_oldProtocolVersion, _diamondCut);
    }

    /// @dev executes upgrade on chain
    function executeUpgrade(uint256 _chainId, Diamond.DiamondCutData calldata _diamondCut) external onlyOwner {
        IZkSyncHyperchain(hyperchainMap.get(_chainId)).executeUpgrade(_diamondCut);
    }

    /// @dev setPriorityTxMaxGasLimit for the specified chain
    function setPriorityTxMaxGasLimit(uint256 _chainId, uint256 _maxGasLimit) external onlyOwner {
        IZkSyncHyperchain(hyperchainMap.get(_chainId)).setPriorityTxMaxGasLimit(_maxGasLimit);
    }

    /// @dev setTokenMultiplier for the specified chain
    function setTokenMultiplier(uint256 _chainId, uint128 _nominator, uint128 _denominator) external onlyOwner {
        IZkSyncHyperchain(hyperchainMap.get(_chainId)).setTokenMultiplier(_nominator, _denominator);
    }

    /// @dev changeFeeParams for the specified chain
    function changeFeeParams(uint256 _chainId, FeeParams calldata _newFeeParams) external onlyOwner {
        IZkSyncHyperchain(hyperchainMap.get(_chainId)).changeFeeParams(_newFeeParams);
    }

    /// @dev setValidator for the specified chain
    function setValidator(uint256 _chainId, address _validator, bool _active) external onlyOwnerOrAdmin {
        IZkSyncHyperchain(hyperchainMap.get(_chainId)).setValidator(_validator, _active);
    }

    /// @dev setPorterAvailability for the specified chain
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

    /// deploys a full set of chains contracts
    function _deployNewChain(
        uint256 _chainId,
        address _baseToken,
        address _sharedBridge,
        address _admin,
        bytes calldata _diamondCut,
        SyncLayerState _syncLayerState
    ) internal returns (address hyperchainAddress) {
        if (getHyperchain(_chainId) != address(0)) {
            // Hyperchain already registered
            return getHyperchain(_chainId);
        }

        // check not registered
        Diamond.DiamondCutData memory diamondCut = abi.decode(_diamondCut, (Diamond.DiamondCutData));

        // check input
        bytes32 cutHashInput = keccak256(_diamondCut);
        require(cutHashInput == initialCutHash, "STM: initial cutHash mismatch");

        bytes memory mandatoryInitData;
        {
            mandatoryInitData = bytes.concat(
                bytes32(_chainId),
                bytes32(uint256(uint160(BRIDGE_HUB))),
                bytes32(uint256(uint160(address(this)))),
                bytes32(uint256(protocolVersion)),
                bytes32(uint256(uint160(_admin))),
                bytes32(uint256(uint160(validatorTimelock))),
                bytes32(uint256(uint160(_baseToken))),
                bytes32(uint256(uint160(_sharedBridge))),
                bytes32(storedBatchZero),
                bytes32(uint256(_syncLayerState))
            );
        }

        // construct init data
        bytes memory initData;
        /// all together 4+9*32=292 bytes
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
    /// @param _diamondCut the diamond cut data that initializes the chains Diamond Proxy
    function createNewChain(
        uint256 _chainId,
        address _baseToken,
        address _sharedBridge,
        address _admin,
        bytes calldata _diamondCut
    ) external onlyBridgehub {
        // TODO: only allow on L1.

        address hyperchainAddress = _deployNewChain(
            _chainId,
            _baseToken,
            _sharedBridge,
            _admin,
            _diamondCut,
            SyncLayerState.ActiveL1
        );

        // set chainId in VM
        IAdmin(hyperchainAddress).setChainIdUpgrade(genesisUpgrade);
    }

    function getProtocolVersion(uint256 _chainId) public view returns (uint256) {
        IZkSyncHyperchain(hyperchainMap.get(_chainId)).getProtocolVersion();
    }

    function registerSyncLayer(uint256 _newSyncLayerChainId, bool _isWhitelisted) external onlyOwner {
        require(_newSyncLayerChainId != 0, "Bad chain id");

        // Currently, we require that the sync layer is deployed by the same STM.
        address syncLayerAddress = hyperchainMap.get(_newSyncLayerChainId);

        // TODO: Maybe `get` already ensured its existance.
        require(syncLayerAddress != address(0), "STM: sync layer not registered");

        IBridgehub(BRIDGE_HUB).registerSyncLayer(_newSyncLayerChainId, _isWhitelisted);

        // TODO: emit event
    }

    function finalizeMigrationToSyncLayer(
        uint256 _chainId,
        address _baseToken,
        address _sharedBridge,
        address _admin,
        uint256 _expectedProtocolVersion,
        HyperchainCommitment calldata _commitment,
        bytes calldata _diamondCut
    ) external {
        /// FIXME: adequate access rights

        address currentAddress = getHyperchain(_chainId);

        // We do not want to deal with inactive protocol versions during migration.
        require(_expectedProtocolVersion == protocolVersion, "STM: not latest protocol version");

        // Just in case
        require(protocolVersionIsActive(_expectedProtocolVersion), "STM: protocolVersion not active");

        if (currentAddress == address(0)) {
            require(protocolVersion == _expectedProtocolVersion, "STM: protocolVersion mismatch");

            // We set "migrated L2 initially" as it will be reset later on in the `finalizeMigration` call.
            currentAddress = _deployNewChain(
                _chainId,
                _baseToken,
                _sharedBridge,
                _admin,
                _diamondCut,
                SyncLayerState.MigratedSL
            );

            // note that we do not need the genesis upgrade, it is expected that everything is already prepared on l2.
        }

        IZkSyncHyperchain hyperchain = IZkSyncHyperchain(hyperchainMap.get(_chainId));

        uint256 currentProtocolVersion = hyperchain.getProtocolVersion();
        // while it should be definitely the case when a chain is created, we double check just in case
        require(currentProtocolVersion == _expectedProtocolVersion, "STM: protocolVersion mismatch");

        // Now migrating the chain
        hyperchain.finalizeMigration(_commitment);
    }

    function finalizeMigrationFromSyncLayer(uint256 _chainId) external {
        // FIXME: this method should check that a certain message was sent from the SL to L1.

        require(false, "TODO");

        // address currentAddress = getHyperchain(_chainId);
        // // On L1 we do expect that the chain is already registered.
        // require(currentAddress != address(0), "STM: chain not registered");

        // _finalizeMigration(
        //     _chainId,
        //     _baseToken,
        //     _sharedBridge,
        //     _admin,
        //     _expectedProtocolVersion,
        //     commitment
        // );
    }

    // function _finalizeMigration(
    //     uint256 _chainId,
    //     address _baseToken,
    //     address _sharedBridge,
    //     address _admin,
    //     uint256 _expectedProtocolVersion,
    //     HyperchainCommitment calldata commitment
    // ) {

    // }

    function startMigrationToSyncLayer(
        uint256 _chainId,
        uint256 _syncLayerChainId,
        address _newSyncLayerAdmin,
        L2TransactionRequestDirect memory _request,
        bytes calldata _diamondCut
    ) external payable {
        // TODO: Maybe check l2 diamond cut here for failing fast?

        require(_newSyncLayerAdmin != address(0), "STM: admin zero");

        // TODO: add requiremenet for it to be a admin of the chain
        require(IBridgehub(BRIDGE_HUB).whitelistedSyncLayers(_syncLayerChainId), "sync layer not whitelisted");

        // TODO: double check that get only returns when chain id is there.
        IZkSyncHyperchain hyperchain = IZkSyncHyperchain(hyperchainMap.get(_chainId));

        address chainBaseToken = hyperchain.getBaseToken();
        uint256 currentProtocolVersion = hyperchain.getProtocolVersion();
        require(currentProtocolVersion == protocolVersion, "STM: protocolVersion not up to date");

        // FIXME: this will be removed once we support the migration of the priority queue also.
        require(hyperchain.getPriorityQueueSize() == 0, "Migration is only allowed with empty priority queue");

        HyperchainCommitment memory commitment = hyperchain.startMigrationToSyncLayer(_syncLayerChainId);

        bytes memory migrationCalldata = abi.encodeCall(
            IBridgehub.finalizeMigrationToSyncLayer,
            (
                _chainId,
                chainBaseToken,
                IBridgehub(BRIDGE_HUB).bridgehubCounterParts(_syncLayerChainId),
                _newSyncLayerAdmin,
                currentProtocolVersion,
                commitment,
                _diamondCut
            )
        );

        require(_request.chainId == _syncLayerChainId, "chain id incorrect");
        // We assume that the sync layer always has eth as its base token.
        require(_request.mintValue == msg.value, "Not enough value sent");

        // It should be checked by the mailbox of the chain also, but just in case
        require(_request.l2Value <= _request.mintValue, "L2 value too large");

        _request.l2Calldata = migrationCalldata;

        bytes32 canonicalHash = IBridgehub(BRIDGE_HUB).requestL2TransactionDirect{value: msg.value}(_request);

        lastMigrationTxHashes[_chainId] = canonicalHash;
        // lastMigratedCommitments[_chainId] = keccak256(abi.encode(commitment));
        // Now, we need to send an L1->L2 tx to the sync layer blockchain to the spawn the chain on SL.
        // We just send it via a normal L-Z
    }

    /// @dev This internal function is used to register a new hyperchain in the system.
    function _registerNewHyperchain(uint256 _chainId, address _hyperchain) internal {
        // slither-disable-next-line unused-return
        hyperchainMap.set(_chainId, _hyperchain);
        require(hyperchainMap.length() <= MAX_NUMBER_OF_HYPERCHAINS, "STM: Hyperchain limit reached");
        emit NewHyperchain(_chainId, _hyperchain);
    }
}
