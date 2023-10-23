// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "./l2-deps/ISystemContext.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA, L2_TO_L1_LOG_SERIALIZE_SIZE, DEFAULT_L2_LOGS_TREE_ROOT_HASH, EMPTY_STRING_KECCAK} from "../common/Config.sol";
import {L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR, L2_FORCE_DEPLOYER_ADDR} from "../common/L2ContractAddresses.sol";

import "../common/DiamondProxy.sol";
import {ProofInitializeData} from "./state-transition-interfaces/IStateTransitionDiamondInit.sol";
import {IStateTransition} from "./state-transition-interfaces/IStateTransition.sol";
import "./state-transition-deps/StateTransitionBase.sol";
import "../bridgehub/bridgehub-interfaces/IBridgehub.sol";
import "./chain-interfaces/IDiamondInit.sol";

/// @title StateTransition conract
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract StateTransition is IStateTransition, StateTransitionBase {
    using UncheckedMath for uint256;

    /// initialize
    function initialize(ProofInitializeData calldata _initializeData) external reentrancyGuardInitializer {
        require(_initializeData.governor != address(0), "vy");

        proofStorage.bridgehub = _initializeData.bridgehub;
        proofStorage.governor = _initializeData.governor;

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
        proofStorage.storedBatchZero = keccak256(abi.encode(storedBatchZero));

        proofStorage.cutHash = keccak256(abi.encode(_initializeData.diamondCut));

        // While this does not provide a protection in the production, it is needed for local testing
        // Length of the L2Log encoding should not be equal to the length of other L2Logs' tree nodes preimages
        assert(L2_TO_L1_LOG_SERIALIZE_SIZE != 2 * 32);
    }

    /// getters
    /// @return The address of the current governor
    function getGovernor() external view returns (address) {
        return proofStorage.governor;
    }

    function getBridgehub() external view returns (address) {
        return proofStorage.bridgehub;
    }

    function getStateTransitionChainContract(uint256 _chainId) external view returns (address) {
        return proofStorage.stateTransitionChainContract[_chainId];
    }

    /// registry
    // we have to set the chainId, as blockhashzero is the same for all chains, and specifies the genesis chainId
    function _specialSetChainIdInVMTx(uint256 _chainId, address _chainContract) internal {
        WritePriorityOpParams memory params;

        params.sender = L2_FORCE_DEPLOYER_ADDR;
        params.l2Value = 0;
        params.contractAddressL2 = L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR;
        params.l2GasLimit = $(PRIORITY_TX_MAX_GAS_LIMIT);
        params.l2GasPricePerPubdata = REQUIRED_L2_GAS_PRICE_PER_PUBDATA;
        params.refundRecipient = address(0);

        bytes memory setChainIdCalldata = abi.encodeCall(ISystemContext.setChainId, (_chainId));
        bytes[] memory emptyA;

        IMailbox(_chainContract).requestL2TransactionProof(params, setChainIdCalldata, emptyA, true);
    }

    /// @notice
    function newChain(
        uint256 _chainId,
        address _governor,
        Diamond.DiamondCutData calldata _diamondCut
    ) external onlyGovernor {
        // check not registered
        address bridgehub = proofStorage.bridgehub;
        require(proofStorage.stateTransitionChainContract[_chainId] == address(0), "PRegistry 1");
        require(IBridgehub(bridgehub).getChainStateTransition(_chainId) == address(this), "PRegsitry 2");

        // check input
        bytes32 cutHash = keccak256(abi.encode(_diamondCut));
        require(cutHash == proofStorage.cutHash, "PRegistry 3");

        // construct init data
        bytes memory initData;
        bytes memory copiedData = _diamondCut.initCalldata[196:];
        initData = bytes.concat(
            IDiamondInit.initialize.selector,
            bytes32(_chainId),
            bytes32(uint256(uint160(address(bridgehub)))),
            bytes32(uint256(uint160(address(this)))),
            bytes32(uint256(uint160(_governor))),
            bytes32(uint256(uint160(_governor))),
            bytes32(proofStorage.storedBatchZero),
            copiedData
        );
        Diamond.DiamondCutData memory cutData = _diamondCut;
        cutData.initCalldata = initData;

        // deploy stateTransitionChainContract
        DiamondProxy stateTransitionChainContract = new DiamondProxy(block.chainid, cutData);

        // save data
        address stateTransitionChainAddress = address(stateTransitionChainContract);

        proofStorage.stateTransitionChainContract[_chainId] = stateTransitionChainAddress;
        proofStorage.chainNumberToContract[proofStorage.totalChains] = stateTransitionChainAddress;
        ++proofStorage.totalChains;

        IBridgehub(bridgehub).setStateTransitionChainContract(_chainId, stateTransitionChainAddress);

        // set chainId in VM
        _specialSetChainIdInVMTx(_chainId, stateTransitionChainAddress);

        emit StateTransitionNewChain(_chainId, stateTransitionChainAddress);
    }

    function setUpgradeDiamondCut(
        Diamond.DiamondCutData calldata _cutData,
        uint256 _protocolVersion
    ) external onlyGovernor {
        proofStorage.upgradeCutHash[_protocolVersion] = keccak256(abi.encode(_cutData));
    }

    function upgradeChain(
        uint256 _chainId,
        uint256 _protocolVersion,
        Diamond.DiamondCutData calldata _cutData
    ) external onlyChainGovernor(_chainId) {
        bytes32 cutHash = keccak256(abi.encode(_cutData));
        require(cutHash == proofStorage.upgradeCutHash[_protocolVersion], "r25");

        IStateTransitionChain stateTransitionChainContract = IStateTransitionChain(proofStorage.stateTransitionChainContract[_chainId]);
        stateTransitionChainContract.executeUpgrade(_cutData, _protocolVersion);
    }

    function specialUpgradeChain(
        uint256 _chainId,
        uint256 _protocolVersion,
        Diamond.DiamondCutData calldata _cutData
    ) external onlyGovernor {
        IStateTransitionChain stateTransitionChainContract = IStateTransitionChain(proofStorage.stateTransitionChainContract[_chainId]);
        stateTransitionChainContract.executeUpgrade(_cutData, _protocolVersion);
    }

    function freezeNotUpdated() external onlyGovernor {
        uint256 protocolVersion = proofStorage.protocolVersion;
        for (uint256 i = 0; i < proofStorage.totalChains; i = i.uncheckedInc()) {
            IStateTransitionChain stateTransitionChainContract = IStateTransitionChain(proofStorage.chainNumberToContract[i]);
            stateTransitionChainContract.freezeNotUpdated(protocolVersion);
        }
    }
}
