// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {CTMInventoryRow} from "../RegistryTypes.sol";

/// @notice Immutable description of a CTM domain's CURRENT deployment: the address book an
///         upgrade departs from, rather than a list of operations to perform.
/// @dev The distinction is the point. An upgrade row says "move this proxy from A to B"; an
///      inventory row says "this proxy is at B". A transition names a source and a target
///      inventory and DERIVES its operations from the pair, the same way its facet cuts already
///      derive from a release pair — so nothing about the current deployment has to be
///      reconstructed off-chain, and nothing is authored twice.
/// @dev Deliberately does NOT describe what a chain runs. Facets, `DiamondInit`, the verifier and
///      the genesis upgrade are the release's, and those slots are empty here.
interface ICTMRegistry {
    /// @notice `keccak256(abi.encode(manifest))` — the 32 bytes governance approves.
    function manifestHash() external view returns (bytes32);

    /// @notice The CTM whose domain this describes.
    function ctm() external view returns (address);

    /// @notice Every member row, indexed by `CTMContract` (absent members are all-zero rows).
    function members() external view returns (CTMInventoryRow[] memory);

    /// @notice One member's row.
    function member(uint256 _member) external view returns (CTMInventoryRow memory);

    /// @notice Reverts unless every member's pinned implementation is what its proxy actually
    ///         points at, read through the row's administering `ProxyAdmin`.
    /// @param _domainAdmin The CTM domain's own admin, used for rows that name none.
    function validate(address _domainAdmin) external view;

    /// @notice {validate} as a predicate, for tooling and monitors.
    function verifyAll(address _domainAdmin) external view returns (bool);
}
