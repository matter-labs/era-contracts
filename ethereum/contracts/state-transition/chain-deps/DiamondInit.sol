// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../../common/interfaces/IAllowList.sol";
import "../../common/libraries/Diamond.sol";
import "./facets/Base.sol";

import {L2_TX_MAX_GAS_LIMIT, L2_TO_L1_LOG_SERIALIZE_SIZE, REQUIRED_L2_GAS_PRICE_PER_PUBDATA, SYSTEM_UPGRADE_L2_TX_TYPE} from "../../common/Config.sol";
import {L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR, L2_BOOTLOADER_ADDRESS} from "../../common/L2ContractAddresses.sol";
import {InitializeData, IDiamondInit} from "../chain-interfaces/IDiamondInit.sol";

import "../l2-deps/ISystemContext.sol";

/// @author Matter Labs
/// @dev The contract is used only once to initialize the diamond proxy.
/// @dev The deployment process takes care of this contract's initialization.
contract DiamondInit is StateTransitionChainBase, IDiamondInit {
    /// @dev Initialize the implementation to prevent any possibility of a Parity hack.
    constructor() reentrancyGuardInitializer {}

    /// @notice zkSync contract initialization
    /// @return Magic 32 bytes, which indicates that the contract logic is expected to be used as a diamond proxy
    /// initializer
    function initialize(InitializeData calldata _initializeData) external reentrancyGuardInitializer returns (bytes32) {
        require(address(_initializeData.verifier) != address(0), "vt");
        require(_initializeData.governor != address(0), "vy");
        require(_initializeData.admin != address(0), "hc");
        require(_initializeData.priorityTxMaxGasLimit <= L2_TX_MAX_GAS_LIMIT, "vu");

        chainStorage.upToDate = true;
        chainStorage.chainId = _initializeData.chainId;
        chainStorage.stateTransition = _initializeData.stateTransition;
        chainStorage.bridgehub = _initializeData.bridgehub;
        chainStorage.protocolVersion = _initializeData.protocolVersion;

        chainStorage.verifier = _initializeData.verifier;
        chainStorage.governor = _initializeData.governor;
        chainStorage.admin = _initializeData.admin;

        chainStorage.storedBatchHashes[0] = _initializeData.storedBatchZero;
        chainStorage.allowList = _initializeData.allowList;
        chainStorage.verifierParams = _initializeData.verifierParams;
        chainStorage.l2BootloaderBytecodeHash = _initializeData.l2BootloaderBytecodeHash;
        chainStorage.l2DefaultAccountBytecodeHash = _initializeData.l2DefaultAccountBytecodeHash;
        chainStorage.priorityTxMaxGasLimit = _initializeData.priorityTxMaxGasLimit;

        // While this does not provide a protection in the production, it is needed for local testing
        // Length of the L2Log encoding should not be equal to the length of other L2Logs' tree nodes preimages
        assert(L2_TO_L1_LOG_SERIALIZE_SIZE != 2 * 32);

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }

    function setChainIdUpgrade(uint256 _chainId, uint256 _protocolVersion) external returns (bytes32) {
        WritePriorityOpParams memory params;

        bytes memory systemContextCalldata = abi.encodeCall(ISystemContext.setChainId, (_chainId));
        uint256[] memory uintEmptyArray;

        L2CanonicalTransaction memory l2Transaction = L2CanonicalTransaction({
            txType: SYSTEM_UPGRADE_L2_TX_TYPE,
            from: uint256(uint160(L2_BOOTLOADER_ADDRESS)),
            to: uint256(uint160(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR)),
            gasLimit: $(PRIORITY_TX_MAX_GAS_LIMIT),
            gasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            maxFeePerGas: uint256(0),
            maxPriorityFeePerGas: uint256(0),
            paymaster: uint256(0),
            // Note, that the priority operation id is used as "nonce" for L1->L2 transactions
            nonce: _protocolVersion,
            value: 0,
            reserved: [uint256(0), 0, 0, 0],
            data: systemContextCalldata,
            signature: new bytes(0),
            factoryDeps: uintEmptyArray,
            paymasterInput: new bytes(0),
            reservedDynamic: new bytes(0)
        });

        bytes memory encodedTransaction = abi.encode(l2Transaction);

        bytes32 l2ProtocolUpgradeTxHash = keccak256(encodedTransaction);

        emit SetChainIdUpgrade(l2Transaction, block.timestamp, _protocolVersion);

        chainStorage.l2SystemContractsUpgradeTxHash = l2ProtocolUpgradeTxHash;

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}
