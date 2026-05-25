// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

import {IL2FlowEscrow} from "./IL2FlowEscrow.sol";
import {COMMIT_LOG_TAG, SendSpec} from "./IDummyFlow.sol";
import {L2ContractHelper} from "../common/l2-helpers/L2ContractHelper.sol";
import {AddressAliasHelper} from "../vendor/AddressAliasHelper.sol";
import {
    EscrowFlowAlreadyCommitted,
    EscrowFlowAlreadySettled,
    EscrowAlreadyInitialized,
    EscrowOnlyAliasedLinker,
    EscrowSendSpecMissingDest,
    EscrowSendSpecSelfDest,
    EscrowSendSpecZeroAmount,
    EscrowSendSpecZeroRecipient,
    EscrowSendSpecZeroToken,
    EscrowFollowupFailed
} from "./DummyFlowErrors.sol";

/// @notice Minter interface assumed for any token used in `executeFromL1`. The dummy stack
/// uses `TestnetERC20Token` which exposes `mint`; production integrations would swap this
/// for an asset-router-style mint or a per-token bridge custody release.
interface IMintableToken {
    function mint(address _to, uint256 _amount) external returns (bool);
}

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice See `IL2FlowEscrow`. The escrow is userspace — anyone can deploy one and use it
/// with the L1 linker. Each escrow instance is tied to one L1 linker address (set at
/// construction or via `initialize`) and rejects any other aliased sender on the L1-only
/// entries (`executeFromL1`, `refundFromL1`).
contract L2FlowEscrow is IL2FlowEscrow {
    using SafeERC20 for IERC20;

    enum Settlement {
        None,
        Committed,
        Executed,
        Refunded
    }

    /// @dev L1-side address of the linker that drives this escrow. Compared against
    /// `undoL1ToL2Alias(msg.sender)` on every L1-only entry. Set once via `initialize` to
    /// keep the contract free of immutables / constructors so it deploys cleanly under
    /// ZKsync OS as well as Era.
    address public l1Linker;

    struct Commit {
        address depositor;
        SendSpec spec;
    }

    mapping(bytes32 flowId => Commit) internal _commits;
    mapping(bytes32 flowId => Settlement) public settlement;

    /// @notice One-shot initializer. Callable by anyone exactly once; the deployer is
    /// expected to invoke it atomically post-deploy.
    function initialize(address _l1Linker) external {
        if (l1Linker != address(0)) revert EscrowAlreadyInitialized();
        l1Linker = _l1Linker;
    }

    /// @inheritdoc IL2FlowEscrow
    function commitSend(bytes32 _flowId, SendSpec calldata _spec) external {
        if (settlement[_flowId] != Settlement.None) revert EscrowFlowAlreadyCommitted(_flowId);

        _validateSendSpec(_spec);

        settlement[_flowId] = Settlement.Committed;
        _commits[_flowId].depositor = msg.sender;
        // Field-by-field copy: legacy codegen can't whole-struct-copy a calldata struct with
        // a nested dynamic `bytes` into storage.
        SendSpec storage stored = _commits[_flowId].spec;
        stored.destChainId = _spec.destChainId;
        stored.recipient = _spec.recipient;
        stored.token = _spec.token;
        stored.amount = _spec.amount;
        stored.followupTo = _spec.followupTo;
        stored.followupData = _spec.followupData;

        IERC20(_spec.token).safeTransferFrom(msg.sender, address(this), _spec.amount);

        // L2→L1 commit log: the L1 linker reads this back via
        // `IMessageVerification.proveL2MessageInclusionShared` to learn the chain's outbound
        // contribution to the flow. Tag is versioned so the schema can evolve.
        L2ContractHelper.sendMessageToL1(abi.encode(COMMIT_LOG_TAG, _flowId, address(this), _spec));

        emit FlowCommitted(_flowId, msg.sender, _spec);
    }

    /// @inheritdoc IL2FlowEscrow
    function executeFromL1(bytes32 _flowId, SendSpec[] calldata _inboundSpecs) external {
        _requireAliasedLinker();
        Settlement s = settlement[_flowId];
        // Two valid prior states:
        //   None     — this chain is receive-only (never called `commitSend`).
        //   Committed — this chain locked something; settlement now moves to Executed and the
        //               lock is consumed (kept in this contract as bridge custody, matching
        //               the burn-side of a real bridge's burn-and-mint semantics).
        if (s != Settlement.None && s != Settlement.Committed) revert EscrowFlowAlreadySettled(_flowId);
        settlement[_flowId] = Settlement.Executed;

        uint256 n = _inboundSpecs.length;
        for (uint256 i; i < n; ++i) {
            SendSpec calldata inbound = _inboundSpecs[i];
            IMintableToken(inbound.token).mint(inbound.recipient, inbound.amount);

            bool followupInvoked = inbound.followupTo != address(0);
            if (followupInvoked) {
                (bool ok, ) = inbound.followupTo.call(inbound.followupData);
                if (!ok) revert EscrowFollowupFailed(inbound.followupTo, inbound.followupData);
            }

            emit InboundDelivered(_flowId, inbound.recipient, inbound.token, inbound.amount, followupInvoked);
        }

        emit FlowExecuted(_flowId, n);
    }

    /// @inheritdoc IL2FlowEscrow
    function refundFromL1(bytes32 _flowId) external {
        _requireAliasedLinker();
        Settlement s = settlement[_flowId];
        if (s != Settlement.Committed) revert EscrowFlowAlreadySettled(_flowId);

        settlement[_flowId] = Settlement.Refunded;
        Commit storage commit = _commits[_flowId];
        address depositor = commit.depositor;
        IERC20(commit.spec.token).safeTransfer(depositor, commit.spec.amount);

        emit FlowRefunded(_flowId, depositor);
    }

    function getCommit(bytes32 _flowId) external view returns (address depositor, SendSpec memory spec) {
        Commit storage commit = _commits[_flowId];
        return (commit.depositor, commit.spec);
    }

    function _requireAliasedLinker() internal view {
        address unaliased = AddressAliasHelper.undoL1ToL2Alias(msg.sender);
        if (unaliased != l1Linker) revert EscrowOnlyAliasedLinker(msg.sender);
    }

    /// @dev Sanity checks applied at `commitSend`. Receive-only chains skip `commitSend`
    /// entirely, so a spec reaching here must describe a real outbound transfer.
    function _validateSendSpec(SendSpec calldata _spec) internal view {
        if (_spec.destChainId == 0) revert EscrowSendSpecMissingDest();
        if (_spec.destChainId == block.chainid) revert EscrowSendSpecSelfDest(_spec.destChainId);
        if (_spec.amount == 0) revert EscrowSendSpecZeroAmount();
        if (_spec.token == address(0)) revert EscrowSendSpecZeroToken();
        if (_spec.recipient == address(0)) revert EscrowSendSpecZeroRecipient();
    }
}
