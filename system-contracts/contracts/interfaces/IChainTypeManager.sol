// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

/// @dev Type of change over diamond: add/replace/remove facets
enum Action {
    Add,
    Replace,
    Remove
}

/// @dev Parameters for diamond changes that touch one of the facets
/// @param facet The address of facet that's affected by the cut
/// @param action The action that is made on the facet
/// @param isFreezable Denotes whether the facet & all their selectors can be frozen
/// @param selectors An array of unique selectors that belongs to the facet address
// solhint-disable-next-line gas-struct-packing
struct FacetCut {
    address facet;
    Action action;
    bool isFreezable;
    bytes4[] selectors;
}

/// @dev Structure of the diamond proxy changes
/// @param facetCuts The set of changes (adding/removing/replacement) of implementation contracts
/// @param initAddress The address that's delegate called after setting up new facet changes
/// @param initCalldata Calldata for the delegate call to `initAddress`
struct DiamondCutData {
    FacetCut[] facetCuts;
    address initAddress;
    bytes initCalldata;
}

/// @notice The struct that contains the fields that define how a new chain should be created
/// @param genesisUpgrade The address that is used in the diamond cut initialize address on chain creation
/// @param genesisBatchHash Batch hash of the genesis (initial) batch
/// @param genesisIndexRepeatedStorageChanges The serial number of the shortcut storage key for the genesis batch
/// @param genesisBatchCommitment The zk-proof commitment for the genesis batch
/// @param diamondCut The diamond cut for the first upgrade transaction on the newly deployed chain
// solhint-disable-next-line gas-struct-packing
struct ChainCreationParams {
    address genesisUpgrade;
    bytes32 genesisBatchHash;
    uint64 genesisIndexRepeatedStorageChanges;
    bytes32 genesisBatchCommitment;
    DiamondCutData diamondCut;
    bytes forceDeploymentsData;
}

interface IChainTypeManager {
    function setChainCreationParams(ChainCreationParams calldata _chainCreationParams) external;

    function setNewVersionUpgrade(
        DiamondCutData calldata _cutData,
        uint256 _oldProtocolVersion,
        uint256 _oldProtocolVersionDeadline,
        uint256 _newProtocolVersion
    ) external;
}
