// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {MessageRootBase} from "./MessageRootBase.sol";

import {L2_BRIDGEHUB_ADDR, L2_COMPLEX_UPGRADER_ADDR, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT} from "../../common/l2-helpers/L2ContractAddresses.sol";

import {V30UpgradeChainBatchNumberNotSet, OnlyGateway} from "../core/L1BridgehubErrors.sol";
import {MessageHashing} from "../../common/libraries/MessageHashing.sol";

import {FullMerkle} from "../../common/libraries/FullMerkle.sol";
import {DynamicIncrementalMerkle} from "../../common/libraries/DynamicIncrementalMerkle.sol";
import {V30_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE_FOR_GATEWAY} from "./IMessageRoot.sol";
import {InvalidCaller, Unauthorized} from "../../common/L1ContractErrors.sol";
import {SERVICE_TRANSACTION_SENDER} from "../../common/Config.sol";
import {L2_COMPLEX_UPGRADER_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {IBridgehubBase} from "../core/IBridgehubBase.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The MessageRoot contract is responsible for storing the cross message roots of the chains and the aggregated root of all chains.
/// @dev Important: L2 contracts are not allowed to have any immutable variables or constructors. This is needed for compatibility with ZKsyncOS.
contract L2MessageRoot is MessageRootBase {
    using FullMerkle for FullMerkle.FullTree;
    using DynamicIncrementalMerkle for DynamicIncrementalMerkle.Bytes32PushTree;

    /// @dev Chain ID of L1 for bridging reasons.
    uint256 internal l1ChainId;

    /// @notice The chain id of the Gateway chain.
    uint256 public override ERA_GATEWAY_CHAIN_ID;

    /*//////////////////////////////////////////////////////////////
                        IMMUTABLE GETTERS
    //////////////////////////////////////////////////////////////*/

    function _bridgehub() internal view override returns (address) {
        return L2_BRIDGEHUB_ADDR;
    }

    function _eraGatewayChainId() internal view override returns (uint256) {
        return ERA_GATEWAY_CHAIN_ID;
    }

    // A method for backwards compatibility with the old implementation
    function BRIDGE_HUB() public view returns (address) {
        return L2_BRIDGEHUB_ADDR;
    }

    function L1_CHAIN_ID() public view override returns (uint256) {
        return l1ChainId;
    }

    /// @dev Only allows calls from the complex upgrader contract on L2.
    modifier onlyUpgrader() {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert InvalidCaller(msg.sender);
        }
        _;
    }

    modifier onlyServiceTransactionSender() {
        require(msg.sender == SERVICE_TRANSACTION_SENDER, Unauthorized(msg.sender));
        _;
    }

    /// @notice Checks that the Chain ID is the Gateway chain id.
    modifier onlyGateway() {
        if (block.chainid != _eraGatewayChainId()) {
            revert OnlyGateway();
        }
        _;
    }

    /// @notice Initializes the contract.
    /// @dev This function is used to initialize the contract with the initial values.
    /// @param _l1ChainId The chain id of L1.
    function initL2(uint256 _l1ChainId, uint256 _eraGatewayChainId) public onlyUpgrader {
        _disableInitializers();
        ERA_GATEWAY_CHAIN_ID = _eraGatewayChainId;
        l1ChainId = _l1ChainId;
        _initialize();
    }

    /// On L2s the initializer/reinitializer is not called.
    function initializeL2V30Upgrade() external onlyL2 onlyUpgrader {
        uint256[] memory allZKChains = IBridgehubBase(_bridgehub()).getAllZKChainChainIDs();
        _v30InitializeInner(allZKChains);
    }

    /// @notice This function is used to send the V30 upgrade block number from the Gateway to the L1 chain.
    function sendV30UpgradeBlockNumberFromGateway(uint256 _chainId, uint256) external onlyGateway {
        uint256 sentBlockNumber = v30UpgradeChainBatchNumber[_chainId];
        require(
            sentBlockNumber != V30_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE_FOR_GATEWAY && sentBlockNumber != 0,
            V30UpgradeChainBatchNumberNotSet()
        );

        // slither-disable-next-line unused-return
        L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1(
            abi.encodeCall(this.sendV30UpgradeBlockNumberFromGateway, (_chainId, sentBlockNumber))
        );
    }

    /// @notice Adds a new chainBatchRoot to the chainTree.
    /// @param _chainId The ID of the chain whose chainBatchRoot is being added to the chainTree.
    /// @param _batchNumber The number of the batch to which _chainBatchRoot belongs.
    /// @param _chainBatchRoot The value of chainBatchRoot which is being added.
    function addChainBatchRoot(uint256 _chainId, uint256 _batchNumber, bytes32 _chainBatchRoot) public override {
        super.addChainBatchRoot(_chainId, _batchNumber, _chainBatchRoot);

        // Push chainBatchRoot to the chainTree related to specified chainId and get the new root.
        bytes32 chainRoot;
        // slither-disable-next-line unused-return
        (, chainRoot) = chainTree[_chainId].push(MessageHashing.batchLeafHash(_chainBatchRoot, _batchNumber));

        emit AppendedChainBatchRoot(_chainId, _batchNumber, _chainBatchRoot);

        // Update leaf corresponding to the specified chainId with newly acquired value of the chainRoot.
        bytes32 cachedChainIdLeafHash = MessageHashing.chainIdLeafHash(chainRoot, _chainId);
        bytes32 sharedTreeRoot = sharedTree.updateLeaf(chainIndex[_chainId], cachedChainIdLeafHash);

        emit NewChainRoot(_chainId, chainRoot, cachedChainIdLeafHash);

        _emitRoot(sharedTreeRoot);
        historicalRoot[block.number] = sharedTreeRoot;
    }
}
