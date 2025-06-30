// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "../libraries/Diamond.sol";
import {ZKChainBase} from "./facets/ZKChainBase.sol";
import {L2_TO_L1_LOG_SERIALIZE_SIZE, MAX_GAS_PER_TRANSACTION} from "../../common/Config.sol";
import {InitializeData, IDiamondInit} from "../chain-interfaces/IDiamondInit.sol";
import {PriorityQueue} from "../libraries/PriorityQueue.sol";
import {PriorityTree} from "../libraries/PriorityTree.sol";
import {ZeroAddress, EmptyAssetId, TooMuchGas, EmptyBytes32} from "../../common/L1ContractErrors.sol";

import {DiamondInit} from "./DiamondInit.sol";

/// @author Matter Labs
/// @dev The contract is used only once to initialize the diamond proxy.
/// @dev The deployment process takes care of this contract's initialization.
contract DiamondInitZKOS is DiamondInit {
    using PriorityQueue for PriorityQueue.Queue;
    using PriorityTree for PriorityTree.Tree;

    /// @dev Initialize the implementation to prevent any possibility of a Parity hack.
    constructor() reentrancyGuardInitializer {}

    /// @notice ZK chain diamond contract initialization
    /// @return Magic 32 bytes, which indicates that the contract logic is expected to be used as a diamond proxy
    /// initializer
    function initialize(InitializeData calldata _initializeData) public override reentrancyGuardInitializer returns (bytes32) {
        s.boojumOS = true;
        return super.initialize(_initializeData);
    }
}
