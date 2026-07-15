// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IAdmin} from "./IAdmin.sol";
import {ICommitter} from "./ICommitter.sol";
import {IExecutor} from "./IExecutor.sol";
import {IGetters} from "./IGetters.sol";
import {IMailbox} from "./IMailbox.sol";
import {IMigrator} from "./IMigrator.sol";

import {Diamond} from "../libraries/Diamond.sol";

interface IZKChain is IAdmin, ICommitter, IExecutor, IGetters, IMailbox, IMigrator {
    // We need this structure for the server for now
    event ProposeTransparentUpgrade(
        Diamond.DiamondCutData diamondCut,
        uint256 indexed proposalId,
        bytes32 proposalSalt
    );

    /// @notice One-time report of the chain's genesis (batch 0) chain batch root to the settlement
    /// layer's MessageRoot, seeding the chain's interop tree so the atomic-interop timeout-protocol
    /// precondition (every registered chain has at least one batch inside the shared root) holds
    /// from creation. The root is computed and stored by the chain's DiamondInit; the Bridgehub
    /// triggers this in the same transaction as `createNewChain`.
    /// @dev Lives on the Executor facet. Declared here (not in `IExecutor`) because
    /// `ValidatorTimelock` mirrors `IExecutor` and has no business forwarding this call.
    /// @dev Callable only by the Bridgehub (defense in depth). A no-op on chains that store no
    /// genesis root (EraVM chains); reverts once the first real batch has executed, and the
    /// MessageRoot enforces the once-only semantics.
    function reportGenesisRoot() external;
}
