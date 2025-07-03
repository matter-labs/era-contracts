// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {DataEncoding} from "../common/libraries/DataEncoding.sol";

import {ETH_TOKEN_ADDRESS} from "../common/Config.sol";
import {BridgehubBase} from "./BridgehubBase.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The Bridgehub contract serves as the primary entry point for L1->L2 communication,
/// facilitating interactions between end user and bridges.
/// It also manages state transition managers, base tokens, and chain registrations.
/// Bridgehub is also an IL1AssetHandler for the chains themselves, which is used to migrate the chains
/// between different settlement layers (for example from L1 to Gateway).
contract L1Bridgehub is BridgehubBase {
    /// @notice the asset id of Eth. This is only used on L1.
    bytes32 internal immutable ETH_TOKEN_ASSET_ID;

    /// @notice The total number of ZK chains can be created/connected to this CTM.
    /// This is the temporary security measure.
    uint256 public immutable MAX_NUMBER_OF_ZK_CHAINS;

    /// @notice to avoid parity hack
    constructor(address _owner, uint256 _maxNumberOfZKChains) reentrancyGuardInitializer {
        _disableInitializers();
        MAX_NUMBER_OF_ZK_CHAINS = _maxNumberOfZKChains;

        // Note that this assumes that the bridgehub only accepts transactions on chains with ETH base token only.
        // This is indeed true, since the only methods where this immutable is used are the ones with `onlyL1` modifier.
        // We will change this with interop.
        ETH_TOKEN_ASSET_ID = DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS);
        _transferOwnership(_owner);
        _initializeInner();
    }

    /// @notice used to initialize the contract
    /// @notice this contract is also deployed on L2 as a system contract there the owner and the related functions will not be used
    /// @param _owner the owner of the contract
    function initialize(address _owner) external reentrancyGuardInitializer {
        _transferOwnership(_owner);
        _initializeInner();
    }

    /// @notice Used to initialize the contract on L1
    function initializeV2() external initializer {
        _initializeInner();
    }

    function L1_CHAIN_ID() public view override returns (uint256) {
        return block.chainid;
    }

    function _ethTokenAssetId() internal view override returns (bytes32) {
        return ETH_TOKEN_ASSET_ID;
    }

    function _l1ChainId() internal view override returns (uint256) {
        return block.chainid;
    }

    function _maxNumberOfZKChains() internal view override returns (uint256) {
        return MAX_NUMBER_OF_ZK_CHAINS;
    }
}
