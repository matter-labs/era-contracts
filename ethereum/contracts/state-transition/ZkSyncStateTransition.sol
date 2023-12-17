// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA, L2_TO_L1_LOG_SERIALIZE_SIZE, DEFAULT_L2_LOGS_TREE_ROOT_HASH, EMPTY_STRING_KECCAK, SYSTEM_UPGRADE_L2_TX_TYPE} from "../common/Config.sol";
import {L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR, L2_BOOTLOADER_ADDRESS} from "../common/L2ContractAddresses.sol";

import "../common/ReentrancyGuard.sol";
import "./chain-interfaces/IStateTransitionChain.sol";
import "../common/DiamondProxy.sol";
import {ZkSyncStateTransitionInitializeData} from "./state-transition-interfaces/IStateTransitionInit.sol";
import {IZkSyncStateTransition} from "./state-transition-interfaces/IZkSyncStateTransition.sol";
import "../bridgehub/bridgehub-interfaces/IBridgehub.sol";
import "./chain-interfaces/IDiamondInit.sol";
import "../upgrades/IDefaultUpgrade.sol";
import {ProposedUpgrade} from "../upgrades/BaseZkSyncUpgrade.sol";
import "./l2-deps/ISystemContext.sol";

/// @title StateTransition conract
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract ZkSyncStateTransition is IZkSyncStateTransition, ReentrancyGuard {
    using UncheckedMath for uint256;

    string public constant override getName = "ZkSyncStateTransition";

    /// @notice Address of the bridgehub
    address public immutable bridgehub;

    /// @notice Address which will exercise governance over the network i.e. change validator set, conduct upgrades
    address public governor;

    /// @notice Address that the governor proposed as one that will replace it
    address public pendingGovernor;

    /// total number of chains registered in the contract
    uint256 public totalChains;

    /// @notice chainId => chainContract
    mapping(uint256 => address) public stateTransitionChain;

    /// @dev Batch hash zero, calculated at initialization
    bytes32 public storedBatchZero;

    /// @dev Stored cutData for diamond cut
    bytes32 public initialCutHash;

    /// @dev genesisUpgrade contract address, used to setChainId
    address public genesisUpgrade;

    /// @dev current protocolVersion
    uint256 public protocolVersion;

    /// @dev Stored cutData for upgrade diamond cut. protocolVersion => cutHash
    mapping(uint256 => bytes32) public upgradeCutHash;

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(address _bridgehub) reentrancyGuardInitializer {
        bridgehub = _bridgehub;
    }

    /// @notice Checks that the message sender is an active governor
    modifier onlyGovernor() {
        require(msg.sender == governor, "StateTransition: only governor");
        _;
    }

    modifier onlyBridgehub() {
        require(msg.sender == bridgehub, "StateTransition: only bridgehub");
        _;
    }

    modifier onlyChain(uint256 _chainId) {
        require(stateTransitionChain[_chainId] == msg.sender, "StateTransition: only chain");
        _;
    }

    modifier onlyChainGovernor(uint256 _chainId) {
        require(
            IStateTransitionChain(stateTransitionChain[_chainId]).getGovernor() == msg.sender,
            "StateTransition: only chain governor"
        );
        _;
    }

    /// @dev initialize
    function initialize(
        ZkSyncStateTransitionInitializeData calldata _initializeData
    ) external reentrancyGuardInitializer {
        require(_initializeData.governor != address(0), "StateTransition: governor zero");

        governor = _initializeData.governor;
        genesisUpgrade = _initializeData.genesisUpgrade;
        protocolVersion = _initializeData.protocolVersion;

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

    /// @dev set initial cutHash
    function setInitialCutHash(Diamond.DiamondCutData calldata _diamondCut) external onlyGovernor {
        initialCutHash = keccak256(abi.encode(_diamondCut));
    }

    /// @dev set New Version with upgrade from old version
    function setNewVersionUpgrade(
        Diamond.DiamondCutData calldata _cutData,
        uint256 _oldProtocolVersion,
        uint256 _newProtocolVersion
    ) external onlyGovernor {
        upgradeCutHash[_oldProtocolVersion] = keccak256(abi.encode(_cutData));
        protocolVersion = _newProtocolVersion;
    }

    /// @dev set upgrade for some protocolVersion
    function setUpgradeDiamondCut(
        Diamond.DiamondCutData calldata _cutData,
        uint256 _oldProtocolVersion
    ) external onlyGovernor {
        upgradeCutHash[_oldProtocolVersion] = keccak256(abi.encode(_cutData));
    }

    /// upgrade a specific chain
    function upgradeChainFromVersion(
        uint256 _chainId,
        uint256 _oldProtocolVersion,
        Diamond.DiamondCutData calldata _cutData
    ) external onlyChainGovernor(_chainId) {
        bytes32 cutHashInput = keccak256(abi.encode(_cutData));
        require(cutHashInput == upgradeCutHash[_oldProtocolVersion], "StateTransition: cutHash mismatch");

        IStateTransitionChain stateTransitionChainContract = IStateTransitionChain(stateTransitionChain[_chainId]);
        require(
            stateTransitionChainContract.getProtocolVersion() == _oldProtocolVersion,
            "StateTransition: protocolVersion mismatch in STC when upgrading"
        );
        stateTransitionChainContract.executeUpgrade(_cutData);
    }

    /// registration

    /// @dev we have to set the chainId at genesis, as blockhashzero is the same for all chains with the same chainId
    function _setChainIdUpgrade(uint256 _chainId, address _chainContract) internal {
        bytes memory systemContextCalldata = abi.encodeCall(ISystemContext.setChainId, (_chainId));
        uint256[] memory uintEmptyArray;
        bytes[] memory bytesEmptyArray;

        L2CanonicalTransaction memory l2ProtocolUpgradeTx = L2CanonicalTransaction({
            txType: SYSTEM_UPGRADE_L2_TX_TYPE,
            from: uint256(uint160(L2_BOOTLOADER_ADDRESS)),
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
            initCalldata: abi.encodeWithSelector(IDefaultUpgrade.upgrade.selector, proposedUpgrade)
        });

        IAdmin(_chainContract).executeChainIdUpgrade(cutData, l2ProtocolUpgradeTx, protocolVersion);
    }

    /// @notice called by Bridgehub when a chain registers
    function newChain(uint256 _chainId, address _governor, bytes calldata _diamondCut) external onlyBridgehub {
        // check not registered
        Diamond.DiamondCutData memory diamondCut = abi.decode(_diamondCut, (Diamond.DiamondCutData));

        // check input
        bytes32 cutHashInput = keccak256(_diamondCut);
        require(cutHashInput == initialCutHash, "StateTransition: initial cutHash mismatch");

        // construct init data
        bytes memory initData;
        initData = bytes.concat(
            IDiamondInit.initialize.selector,
            bytes32(_chainId),
            bytes32(uint256(uint160(address(bridgehub)))),
            bytes32(uint256(uint160(address(this)))),
            bytes32(uint256(protocolVersion)),
            bytes32(uint256(uint160(_governor))),
            bytes32(uint256(uint160(_governor))),
            bytes32(storedBatchZero),
            diamondCut.initCalldata
        );

        diamondCut.initCalldata = initData;
        // deploy stateTransitionChainContract
        DiamondProxy stateTransitionChainContract = new DiamondProxy(block.chainid, diamondCut);

        // save data
        address stateTransitionChainAddress = address(stateTransitionChainContract);

        stateTransitionChain[_chainId] = stateTransitionChainAddress;
        ++totalChains;

        // set chainId in VM
        _setChainIdUpgrade(_chainId, stateTransitionChainAddress);

        emit StateTransitionNewChain(_chainId, stateTransitionChainAddress);
    }
}
