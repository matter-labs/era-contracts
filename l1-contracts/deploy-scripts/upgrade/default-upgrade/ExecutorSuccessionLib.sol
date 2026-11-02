// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";

import {Call} from "contracts/governance/Common.sol";
import {IUpgradeExecutorBase} from "contracts/governance/IUpgradeExecutorBase.sol";
import {ICTMUpgradeExecutor} from "contracts/upgrades/registry/executors/ICTMUpgradeExecutor.sol";

/// @notice The governance calls that hand a domain from its executor to a successor
///         ("Executor succession" in {docs/upgrade-operations.md}). An upgrade that replaces an
///         executor carries them right before its executor legs, which then target the successor.
///         protocol-ops derives the same calls (`derive_executor_succession`) and holds the merged
///         bundle to them; this library is the Solidity statement the Foundry harnesses use.
/// @dev Fixed shapes, no authored calldata: every call is determined by the predecessor, the
///      successor and the domain's own contracts.
library ExecutorSuccessionLib {
    /// @notice The core domain: the predecessor hands the ecosystem `ProxyAdmin` (a one-step
    ///         `Ownable`) to the successor.
    /// @param _predecessor The executor that owns `_proxyAdmin` now.
    /// @param _successor The executor that takes it.
    /// @param _proxyAdmin The ecosystem `ProxyAdmin`.
    /// @return calls One `forward` on the predecessor.
    function coreCalls(
        address _predecessor,
        address _successor,
        address _proxyAdmin
    ) internal pure returns (Call[] memory calls) {
        Call[] memory handover = new Call[](1);
        handover[0] = _call(_proxyAdmin, abi.encodeCall(Ownable.transferOwnership, (_successor)));
        calls = new Call[](1);
        calls[0] = _call(_predecessor, abi.encodeCall(IUpgradeExecutorBase.forward, (handover)));
    }

    /// @notice A CTM domain: the predecessor nominates the successor on the CTM and the
    ///         ServerNotifier (both `Ownable2Step`) and hands over the CTM-domain `ProxyAdmin`
    ///         (one-step); the successor then accepts both nominations.
    /// @param _predecessor The executor that holds the domain now.
    /// @param _successor The executor that takes it.
    /// @param _ctm The ChainTypeManager proxy.
    /// @param _ctmProxyAdmin The CTM-domain `ProxyAdmin`.
    /// @param _serverNotifier The CTM's ServerNotifier proxy.
    /// @return calls The predecessor's `forward`, the successor's `acceptCTMOwnership`, and the
    ///         successor's `forward` accepting the notifier.
    function ctmCalls(
        address _predecessor,
        address _successor,
        address _ctm,
        address _ctmProxyAdmin,
        address _serverNotifier
    ) internal pure returns (Call[] memory calls) {
        Call[] memory handover = new Call[](3);
        handover[0] = _call(_ctm, abi.encodeCall(Ownable.transferOwnership, (_successor)));
        handover[1] = _call(_ctmProxyAdmin, abi.encodeCall(Ownable.transferOwnership, (_successor)));
        handover[2] = _call(_serverNotifier, abi.encodeCall(Ownable.transferOwnership, (_successor)));
        Call[] memory acceptNotifier = new Call[](1);
        acceptNotifier[0] = _call(_serverNotifier, abi.encodeCall(Ownable2Step.acceptOwnership, ()));

        calls = new Call[](3);
        calls[0] = _call(_predecessor, abi.encodeCall(IUpgradeExecutorBase.forward, (handover)));
        calls[1] = _call(_successor, abi.encodeCall(ICTMUpgradeExecutor.acceptCTMOwnership, ()));
        calls[2] = _call(_successor, abi.encodeCall(IUpgradeExecutorBase.forward, (acceptNotifier)));
    }

    function _call(address _target, bytes memory _data) private pure returns (Call memory) {
        return Call({target: _target, value: 0, data: _data});
    }
}
