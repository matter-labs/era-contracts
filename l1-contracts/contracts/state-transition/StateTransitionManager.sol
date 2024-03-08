// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {Diamond} from "./libraries/Diamond.sol";
import {DiamondProxy} from "./chain-deps/DiamondProxy.sol";
import {IAdmin} from "./chain-interfaces/IAdmin.sol";
import {IDefaultUpgrade} from "../upgrades/IDefaultUpgrade.sol";
import {IDiamondInit} from "./chain-interfaces/IDiamondInit.sol";
import {IExecutor} from "./chain-interfaces/IExecutor.sol";
import {IStateTransitionManager, StateTransitionManagerInitializeData} from "./IStateTransitionManager.sol";
import {ISystemContext} from "./l2-deps/ISystemContext.sol";
import {IZkSyncStateTransition} from "./chain-interfaces/IZkSyncStateTransition.sol";
import {L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR, L2_FORCE_DEPLOYER_ADDR} from "../common/L2ContractAddresses.sol";
import {L2CanonicalTransaction} from "../common/Messaging.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ProposedUpgrade} from "../upgrades/BaseZkSyncUpgrade.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA, L2_TO_L1_LOG_SERIALIZE_SIZE, DEFAULT_L2_LOGS_TREE_ROOT_HASH, EMPTY_STRING_KECCAK, SYSTEM_UPGRADE_L2_TX_TYPE, ERA_DIAMOND_PROXY, ERA_CHAIN_ID} from "../common/Config.sol";
import {VerifierParams} from "./chain-interfaces/IVerifier.sol";

/// @title StateTransition contract
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract StateTransitionManager is IStateTransitionManager, ReentrancyGuard, Ownable2Step {
    /// @notice Address of the bridgehub
    address public immutable bridgehub;

    /// @notice chainId => chainContract
    mapping(uint256 => address) public stateTransition;

    /// @dev Batch hash zero, calculated at initialization
    bytes32 public storedBatchZero;

    /// @dev Stored cutData for diamond cut
    bytes32 public initialCutHash;

    /// @dev genesisUpgrade contract address, used to setChainId
    address public genesisUpgrade;

    /// @dev current protocolVersion
    uint256 public protocolVersion;

    /// @dev validatorTimelock contract address, used to setChainId
    address public validatorTimelock;

    /// @dev Stored cutData for upgrade diamond cut. protocolVersion => cutHash
    mapping(uint256 => bytes32) public upgradeCutHash;

    /// @dev used to manage non critical updates
    address public admin;

    /// @dev used to accept the admin role
    address private pendingAdmin;

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(address _bridgehub) reentrancyGuardInitializer {
        bridgehub = _bridgehub;
    }

    /// @notice only the bridgehub can call
    modifier onlyBridgehub() {
        require(msg.sender == bridgehub, "StateTransition: only bridgehub");
        _;
    }

    /// @notice the admin can call, for non-critical updates
    modifier onlyOwnerOrAdmin() {
        require(msg.sender == admin || msg.sender == owner(), "Bridgehub: not owner or admin");
        _;
    }

    function getChainAdmin(uint256 _chainId) external view override returns (address) {
        return IZkSyncStateTransition(stateTransition[_chainId]).getAdmin();
    }

    /// @dev initialize
    function initialize(
        StateTransitionManagerInitializeData calldata _initializeData
    ) external reentrancyGuardInitializer {
        require(_initializeData.governor != address(0), "StateTransition: governor zero");
        _transferOwnership(_initializeData.governor);

        genesisUpgrade = _initializeData.genesisUpgrade;
        protocolVersion = _initializeData.protocolVersion;
        validatorTimelock = _initializeData.validatorTimelock;

        // We need to initialize the state hash because it is used in the commitment of the next batch
        IExecutor.StoredBatchInfo memory batchZero = IExecutor.StoredBatchInfo(
            0,
            _initializeData.genesisBatchHash,
            _initializeData.genesisIndexRepeatedStorageChanges,
            0,
            EMPTY_STRING_KECCAK,
            DEFAULT_L2_LOGS_TREE_ROOT_HASH,
            0,
            _initializeData.genesisBatchCommitment
        );
        storedBatchZero = keccak256(abi.encode(batchZero));

        initialCutHash = keccak256(abi.encode(_initializeData.diamondCut));

        // While this does not provide a protection in the production, it is needed for local testing
        // Length of the L2Log encoding should not be equal to the length of other L2Logs' tree nodes preimages
        assert(L2_TO_L1_LOG_SERIALIZE_SIZE != 2 * 32);
    }

    /// @inheritdoc IStateTransitionManager
    function setPendingAdmin(address _newPendingAdmin) external onlyOwnerOrAdmin {
        // Save previous value into the stack to put it into the event later
        address oldPendingAdmin = pendingAdmin;
        // Change pending admin
        pendingAdmin = _newPendingAdmin;
        emit NewPendingAdmin(oldPendingAdmin, _newPendingAdmin);
    }

    /// @inheritdoc IStateTransitionManager
    function acceptAdmin() external {
        address currentPendingAdmin = pendingAdmin;
        require(msg.sender == currentPendingAdmin, "n42"); // Only proposed by current admin address can claim the admin rights

        address previousAdmin = admin;
        admin = currentPendingAdmin;
        delete pendingAdmin;

        emit NewPendingAdmin(currentPendingAdmin, address(0));
        emit NewAdmin(previousAdmin, pendingAdmin);
    }

    /// @dev set validatorTimelock. Cannot do it an initialization, as validatorTimelock is deployed after STM
    function setValidatorTimelock(address _validatorTimelock) external onlyOwnerOrAdmin {
        validatorTimelock = _validatorTimelock;
    }

    /// @dev set initial cutHash
    function setInitialCutHash(Diamond.DiamondCutData calldata _diamondCut) external onlyOwner {
        initialCutHash = keccak256(abi.encode(_diamondCut));
    }

    /// @dev set New Version with upgrade from old version
    function setNewVersionUpgrade(
        Diamond.DiamondCutData calldata _cutData,
        uint256 _oldProtocolVersion,
        uint256 _newProtocolVersion
    ) external onlyOwner {
        upgradeCutHash[_oldProtocolVersion] = keccak256(abi.encode(_cutData));
        protocolVersion = _newProtocolVersion;
    }

    /// @dev set upgrade for some protocolVersion
    function setUpgradeDiamondCut(
        Diamond.DiamondCutData calldata _cutData,
        uint256 _oldProtocolVersion
    ) external onlyOwner {
        upgradeCutHash[_oldProtocolVersion] = keccak256(abi.encode(_cutData));
    }

    /// @dev freezes the specified chain
    function freezeChain(uint256 _chainId) external onlyOwner {
        IZkSyncStateTransition(stateTransition[_chainId]).freezeDiamond();
    }

    /// @dev freezes the specified chain
    function unfreezeChain(uint256 _chainId) external onlyOwner {
        IZkSyncStateTransition(stateTransition[_chainId]).freezeDiamond();
    }

    /// @dev reverts batches on the specified chain
    function revertBatches(uint256 _chainId, uint256 _newLastBatch) external onlyOwnerOrAdmin {
        IZkSyncStateTransition(stateTransition[_chainId]).revertBatches(_newLastBatch);
    }

    /// registration

    /// @dev we have to set the chainId at genesis, as blockhashzero is the same for all chains with the same chainId
    function _setChainIdUpgrade(uint256 _chainId, address _chainContract) internal {
        bytes memory systemContextCalldata = abi.encodeCall(ISystemContext.setChainId, (_chainId));
        uint256[] memory uintEmptyArray;
        bytes[] memory bytesEmptyArray;

        L2CanonicalTransaction memory l2ProtocolUpgradeTx = L2CanonicalTransaction({
            txType: SYSTEM_UPGRADE_L2_TX_TYPE,
            from: uint256(uint160(L2_FORCE_DEPLOYER_ADDR)),
            to: uint256(uint160(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR)),
            gasLimit: $(PRIORITY_TX_MAX_GAS_LIMIT),
            gasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            maxFeePerGas: uint256(0),
            maxPriorityFeePerGas: uint256(0),
            paymaster: uint256(0),
            // Note, that the priority operation id is used as "nonce" for L1->L2 transactions
            nonce: protocolVersion,
            value: 0,
            reserved: [uint256(0), 0, 0, 0],
            data: systemContextCalldata,
            signature: new bytes(0),
            factoryDeps: uintEmptyArray,
            paymasterInput: new bytes(0),
            reservedDynamic: new bytes(0)
        });

        ProposedUpgrade memory proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: l2ProtocolUpgradeTx,
            factoryDeps: bytesEmptyArray,
            bootloaderHash: bytes32(0),
            defaultAccountHash: bytes32(0),
            verifier: address(0),
            verifierParams: VerifierParams({
                recursionNodeLevelVkHash: bytes32(0),
                recursionLeafLevelVkHash: bytes32(0),
                recursionCircuitsSetVksHash: bytes32(0)
            }),
            l1ContractsUpgradeCalldata: new bytes(0),
            postUpgradeCalldata: new bytes(0),
            upgradeTimestamp: 0,
            newProtocolVersion: protocolVersion
        });

        Diamond.FacetCut[] memory emptyArray;
        Diamond.DiamondCutData memory cutData = Diamond.DiamondCutData({
            facetCuts: emptyArray,
            initAddress: genesisUpgrade,
            initCalldata: abi.encodeCall(IDefaultUpgrade.upgrade, (proposedUpgrade))
        });

        IAdmin(_chainContract).executeUpgrade(cutData);
        emit SetChainIdUpgrade(_chainContract, l2ProtocolUpgradeTx, protocolVersion);
    }

    function registerAlreadyDeployedStateTransition(
        uint256 _chainId,
        address _stateTransitionContract
    ) external onlyOwner {
        stateTransition[_chainId] = _stateTransitionContract;
        emit StateTransitionNewChain(_chainId, _stateTransitionContract);
    }

    /// @notice called by Bridgehub when a chain registers
    function createNewChain(
        uint256 _chainId,
        address _baseToken,
        address _sharedBridge,
        address _admin,
        bytes calldata _diamondCut
    ) external onlyBridgehub {
        if (stateTransition[_chainId] != address(0)) {
            // StateTransition chain already registered
            return;
        }

        // check not registered
        Diamond.DiamondCutData memory diamondCut = abi.decode(_diamondCut, (Diamond.DiamondCutData));

        // check input
        bytes32 cutHashInput = keccak256(_diamondCut);
        require(cutHashInput == initialCutHash, "StateTransition: initial cutHash mismatch");

        // construct init data
        bytes memory initData;
        /// all together 4+9*32=292 bytes
        initData = bytes.concat(
            IDiamondInit.initialize.selector,
            bytes32(_chainId),
            bytes32(uint256(uint160(bridgehub))),
            bytes32(uint256(uint160(address(this)))),
            bytes32(uint256(protocolVersion)),
            bytes32(uint256(uint160(_admin))),
            bytes32(uint256(uint160(validatorTimelock))),
            bytes32(uint256(uint160(_baseToken))),
            bytes32(uint256(uint160(_sharedBridge))),
            bytes32(storedBatchZero),
            diamondCut.initCalldata
        );

        diamondCut.initCalldata = initData;
        // deploy stateTransitionContract
        DiamondProxy stateTransitionContract = new DiamondProxy{salt: bytes32(0)}(block.chainid, diamondCut);

        // save data
        address stateTransitionAddress = address(stateTransitionContract);

        stateTransition[_chainId] = stateTransitionAddress;

        // set chainId in VM
        _setChainIdUpgrade(_chainId, stateTransitionAddress);

        emit StateTransitionNewChain(_chainId, stateTransitionAddress);
    }
}
