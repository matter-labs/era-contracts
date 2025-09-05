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
/// @dev Important: L2 contracts are not allowed to have any constructor. This is needed for compatibility with ZKsyncOS.
contract L2Bridgehub is BridgehubBase {
    /// @notice the asset id of Eth. This is only used on L1.
    /// @dev Note, that while it is a simple storage variable, the name is in capslock for the backward compatibility with
    /// the old version where it was an immutable.
    bytes32 internal ETH_TOKEN_ASSET_ID;

    /// @notice The chain id of L1. This contract can be deployed on multiple layers, but this value is still equal to the
    /// L1 that is at the most base layer.
    /// @dev Note, that while it is a simple storage variable, the name is in capslock for the backward compatibility with
    /// the old version where it was an immutable.
    uint256 public L1_CHAIN_ID;

    /// @notice The total number of ZK chains can be created/connected to this CTM.
    /// This is the temporary security measure.
    /// @dev Note, that while it is a simple storage variable, the name is in capslock for the backward compatibility with
    /// the old version where it was an immutable.
    uint256 public MAX_NUMBER_OF_ZK_CHAINS;

    /// @notice Initializes the contract
    /// @dev This function is used to initialize the contract with the initial values.
    /// @dev This function is called both for new chains.
    /// @param _l1ChainId The chain id of L1.
    /// @param _owner The owner of the contract.
    /// @param _maxNumberOfZKChains The maximum number of ZK chains that can be created.
    function initL2(
        uint256 _l1ChainId,
        address _owner,
        uint256 _maxNumberOfZKChains
    ) public reentrancyGuardInitializer onlyUpgrader {
        _disableInitializers();
        updateL2(_l1ChainId, _maxNumberOfZKChains);
        _transferOwnership(_owner);
        _initializeInner();
    }

    /// @notice Updates the contract.
    /// @dev This function is used to initialize the new implementation of L2Bridgehub on existing chains during
    /// the upgrade.
    /// @param _l1ChainId The chain id of L1.
    /// @param _maxNumberOfZKChains The maximum number of ZK chains that can be created.
    function updateL2(uint256 _l1ChainId, uint256 _maxNumberOfZKChains) public onlyUpgrader {
        L1_CHAIN_ID = _l1ChainId;
        MAX_NUMBER_OF_ZK_CHAINS = _maxNumberOfZKChains;

        // Note that this assumes that the bridgehub only accepts transactions on chains with ETH base token only.
        // This is indeed true, since the only methods where this immutable is used are the ones with `onlyL1` modifier.
        // We will change this with interop.
        ETH_TOKEN_ASSET_ID = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, ETH_TOKEN_ADDRESS);
    }

    function _ethTokenAssetId() internal view override returns (bytes32) {
        return ETH_TOKEN_ASSET_ID;
    }

    function _l1ChainId() internal view override returns (uint256) {
        return L1_CHAIN_ID;
    }

    function _maxNumberOfZKChains() internal view override returns (uint256) {
        return MAX_NUMBER_OF_ZK_CHAINS;
    }
}
