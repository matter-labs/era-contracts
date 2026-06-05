// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice L2-side store of global interop-IMT roots imported from L1.
///
/// This is the atomic-interop analogue of {IL2InteropRootStorage}: each imported root is treated
/// like an interop dependency. In production the bootloader would write these; in the demo a
/// trusted off-chain "IMT supplier" (an EOA) reads {IGlobalInteropIMT} on L1 and calls
/// `importGlobalRoot` here. Roots are keyed by the originating L1 block number and carry the L1
/// timestamp, which the escrow compares against a flow deadline.
///
/// Deployed in L2 userspace (CREATE2), so it has no constructor — wiring is done in `initialize`.
interface IL2GlobalInteropRootImporter {
    /// @notice Emitted when a global root is imported.
    event GlobalRootImported(uint256 indexed l1BlockNumber, uint256 l1Timestamp, bytes32 globalRoot);

    /// @notice Import a global interop-IMT root snapshot from L1. Callable only by the supplier.
    /// Re-importing the same `(l1BlockNumber, globalRoot)` is a no-op; a conflicting root reverts.
    /// @param _l1BlockNumber The L1 block number the global root was recorded at.
    /// @param _l1Timestamp The L1 timestamp recorded for that root.
    /// @param _globalRoot The aggregated global interop-IMT root.
    function importGlobalRoot(uint256 _l1BlockNumber, uint256 _l1Timestamp, bytes32 _globalRoot) external;

    /// @notice The imported global root for `_l1BlockNumber` (0 if not imported).
    function globalRootAt(uint256 _l1BlockNumber) external view returns (bytes32);

    /// @notice The imported L1 timestamp for `_l1BlockNumber`.
    function timestampAt(uint256 _l1BlockNumber) external view returns (uint256);

    /// @notice Whether a global root has been imported for `_l1BlockNumber`.
    function isImported(uint256 _l1BlockNumber) external view returns (bool);

    /// @notice Number of distinct L1 blocks imported.
    function importedCount() external view returns (uint256);

    /// @notice The `_i`-th imported L1 block number (insertion order).
    function importedBlockAt(uint256 _i) external view returns (uint256);

    /// @notice The trusted supplier address.
    function supplier() external view returns (address);
}
