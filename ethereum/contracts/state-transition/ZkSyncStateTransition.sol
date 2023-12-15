// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA, L2_TO_L1_LOG_SERIALIZE_SIZE, DEFAULT_L2_LOGS_TREE_ROOT_HASH, EMPTY_STRING_KECCAK, SYSTEM_UPGRADE_L2_TX_TYPE} from "../common/Config.sol";
import {L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR, L2_BOOTLOADER_ADDRESS} from "../common/L2ContractAddresses.sol";

import "../common/DiamondProxy.sol";
import {ZkSyncStateTransitionInitializeData} from "./state-transition-interfaces/IStateTransitionInit.sol";
import {IZkSyncStateTransition} from "./state-transition-interfaces/IZkSyncStateTransition.sol";
import "./state-transition-deps/StateTransitionBase.sol";
import "../bridgehub/bridgehub-interfaces/IBridgehub.sol";
import "./chain-interfaces/IDiamondInit.sol";
import "../upgrades/IDefaultUpgrade.sol";
import {ProposedUpgrade} from "../upgrades/BaseZkSyncUpgrade.sol";
import "./l2-deps/ISystemContext.sol";

/// @title StateTransition conract
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract ZkSyncStateTransition is IZkSyncStateTransition, ZkSyncStateTransitionBase {
    using UncheckedMath for uint256;

    string public constant override getName = "ZkSyncStateTransition";

    /// initialize
    function initialize(
        ZkSyncStateTransitionInitializeData calldata _initializeData
    ) external reentrancyGuardInitializer {
        require(_initializeData.governor != address(0), "StateTransition: governor zero");

        stateTransitionStorage.bridgehub = _initializeData.bridgehub;
        stateTransitionStorage.governor = _initializeData.governor;
        stateTransitionStorage.genesisUpgrade = _initializeData.genesisUpgrade;
        stateTransitionStorage.protocolVersion = _initializeData.protocolVersion;

        // We need to initialize the state hash because it is used in the commitment of the next batch
        IExecutor.StoredBatchInfo memory storedBatchZero = IExecutor.StoredBatchInfo(
            0,
            _initializeData.genesisBatchHash,
            _initializeData.genesisIndexRepeatedStorageChanges,
            0,
            EMPTY_STRING_KECCAK,
            DEFAULT_L2_LOGS_TREE_ROOT_HASH,
            0,
            _initializeData.genesisBatchCommitment
        );
        stateTransitionStorage.storedBatchZero = keccak256(abi.encode(storedBatchZero));

        stateTransitionStorage.cutHash = keccak256(abi.encode(_initializeData.diamondCut));

        // While this does not provide a protection in the production, it is needed for local testing
        // Length of the L2Log encoding should not be equal to the length of other L2Logs' tree nodes preimages
        assert(L2_TO_L1_LOG_SERIALIZE_SIZE != 2 * 32);
    }

    /// getters
    /// @return The address of the current governor
    function getGovernor() external view returns (address) {
        return stateTransitionStorage.governor;
    }

    /// @return The address of the current governor
    function getPendingGovernor() external view returns (address) {
        return stateTransitionStorage.pendingGovernor;
    }

    function getBridgehub() external view returns (address) {
        return stateTransitionStorage.bridgehub;
    }

    /// @return The address of the current governor
    function getTotalChains() external view returns (uint256) {
        return stateTransitionStorage.totalChains;
    }

    function getChainNumberToContract(uint256 _chainNumber) external view returns (address) {
        return stateTransitionStorage.stateTransitionChainContract[_chainNumber];
    }

    function getStateTransitionChain(uint256 _chainId) external view returns (address) {
        return stateTransitionStorage.stateTransitionChainContract[_chainId];
    }

    /// @return The address of the current governor
    function getStoredBatchZero() external view returns (bytes32) {
        return stateTransitionStorage.storedBatchZero;
    }

    /// @return The address of the current governor
    function getCutHash() external view returns (bytes32) {
        return stateTransitionStorage.cutHash;
    }

    /// @return The address of the current governor
    function getGenesisUpgradeAddress() external view returns (address) {
        return stateTransitionStorage.genesisUpgrade;
    }

    /// @return The address of the current governor
    function getUpgradeCutHash(uint256 _protocolVersion) external view returns (bytes32) {
        return stateTransitionStorage.upgradeCutHash[_protocolVersion];
    }

    /// @return The address of the current governor
    function getProtocolVersion() external view returns (uint256) {
        return stateTransitionStorage.protocolVersion;
    }

    /// registry
    // we have to set the chainId, as blockhashzero is the same for all chains, and specifies the genesis chainId
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
            nonce: stateTransitionStorage.protocolVersion,
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
            newProtocolVersion: stateTransitionStorage.protocolVersion
        });

        Diamond.FacetCut[] memory emptyArray;
        Diamond.DiamondCutData memory cutData = Diamond.DiamondCutData({
            facetCuts: emptyArray,
            initAddress: stateTransitionStorage.genesisUpgrade,
            initCalldata: abi.encodeWithSelector(IDefaultUpgrade.upgrade.selector, proposedUpgrade)
        });

        IAdmin(_chainContract).executeChainIdUpgrade(
            cutData,
            l2ProtocolUpgradeTx,
            stateTransitionStorage.protocolVersion
        );
    }

    /// @notice
    function newChain(uint256 _chainId, address _governor, bytes calldata _diamondCut) external onlyBridgehub {
        // check not registered
        address bridgehub = stateTransitionStorage.bridgehub;
        Diamond.DiamondCutData memory diamondCut = abi.decode(_diamondCut, (Diamond.DiamondCutData));

        // check input
        bytes32 cutHash = keccak256(_diamondCut);
        require(cutHash == stateTransitionStorage.cutHash, "StateTransition: initial cutHash mismatch");

        // construct init data
        bytes memory initData;
        initData = bytes.concat(
            IDiamondInit.initialize.selector,
            bytes32(_chainId),
            bytes32(uint256(uint160(address(bridgehub)))),
            bytes32(uint256(uint160(address(this)))),
            bytes32(uint256(stateTransitionStorage.protocolVersion)),
            bytes32(uint256(uint160(_governor))),
            bytes32(uint256(uint160(_governor))),
            bytes32(stateTransitionStorage.storedBatchZero),
            diamondCut.initCalldata
        );

        diamondCut.initCalldata = initData;
        // deploy stateTransitionChainContract
        DiamondProxy stateTransitionChainContract = new DiamondProxy(block.chainid, diamondCut);

        // save data
        address stateTransitionChainAddress = address(stateTransitionChainContract);

        stateTransitionStorage.stateTransitionChainContract[_chainId] = stateTransitionChainAddress;
        stateTransitionStorage.chainNumberToContract[stateTransitionStorage.totalChains] = stateTransitionChainAddress;
        ++stateTransitionStorage.totalChains;

        // set chainId in VM
        _setChainIdUpgrade(_chainId, stateTransitionChainAddress);

        emit StateTransitionNewChain(_chainId, stateTransitionChainAddress);
    }

    function setUpgradeDiamondCut(
        Diamond.DiamondCutData calldata _cutData,
        uint256 _protocolVersion
    ) external onlyGovernor {
        stateTransitionStorage.upgradeCutHash[_protocolVersion] = keccak256(abi.encode(_cutData));
        stateTransitionStorage.protocolVersion = _protocolVersion;
    }

    function upgradeChain(
        uint256 _chainId,
        uint256 _protocolVersion,
        Diamond.DiamondCutData calldata _cutData
    ) external onlyChainGovernor(_chainId) {
        bytes32 cutHash = keccak256(abi.encode(_cutData));
        require(
            cutHash == stateTransitionStorage.upgradeCutHash[_protocolVersion],
            "StateTransition: cutHash mismatch"
        );

        IStateTransitionChain stateTransitionChainContract = IStateTransitionChain(
            stateTransitionStorage.stateTransitionChainContract[_chainId]
        );
        stateTransitionChainContract.executeUpgrade(_cutData);
    }
}
