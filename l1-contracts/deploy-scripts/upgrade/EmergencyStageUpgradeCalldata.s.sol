// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Script, console2} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {Bytes} from "contracts/vendor/Bytes.sol";
import {GovernanceUpgradeTimer} from "contracts/upgrades/GovernanceUpgradeTimer.sol";
import {EcosystemUpgradeExecutor} from "contracts/upgrades/registry/executors/EcosystemUpgradeExecutor.sol";
import {IEcosystemUpgradeOperation} from "contracts/upgrades/registry/objects/IEcosystemUpgradeOperation.sol";

import {EIP712Utils} from "../utils/EIP712Utils.sol";
import {
    EMERGENCY_UPGRADE_SALT,
    EXECUTE_EMERGENCY_UPGRADE_GUARDIANS_TYPEHASH,
    EXECUTE_EMERGENCY_UPGRADE_SECURITY_COUNCIL_TYPEHASH,
    EXECUTE_EMERGENCY_UPGRADE_ZK_FOUNDATION_TYPEHASH
} from "../utils/Utils.sol";
import {IProtocolUpgradeHandler} from "../interfaces/IProtocolUpgradeHandler.sol";
import {IEmergencyUpgrageBoard} from "../interfaces/IEmergencyUpgrageBoard.sol";
import {IMultisig} from "../interfaces/IMultisig.sol";
import {ISafe} from "../interfaces/ISafe.sol";

/// @notice Emits everything needed to run a prepared upgrade as ONE EMERGENCY upgrade proposal
///         (`EmergencyUpgradeBoard.executeEmergencyUpgrade` -> `ProtocolUpgradeHandler.executeEmergencyUpgrade`)
///         with no private key and no off-chain signing: one owner EOA pre-approves each Safe message
///         hash on-chain (`approveHash`), and the board call carries Gnosis "approved hash" markers.
///         The proposal's calls are every governance call of the merged package
///         `protocol-ops ecosystem upgrade-prepare-all` writes ({loadGovernanceCalls}). Usage and
///         inputs: "Emergency execution" in `deploy-scripts/upgrade/README.md`.
/// @dev Read-only; it reads the board, its multisigs and the Safes' message hashes from L1.
contract EmergencyStageUpgradeCalldata is Script {
    using stdToml for string;

    /// @notice A Safe message hash the owner pre-approves on one approving Safe.
    struct SafeApproval {
        string signer;
        address safe;
        bytes32 safeMessageHash;
    }

    /// @notice One emergency proposal: what the owner approves and what the board is then called with.
    struct EmergencyProposal {
        IEmergencyUpgrageBoard board;
        address owner;
        bytes32 id;
        IProtocolUpgradeHandler.Call[] calls;
        SafeApproval[] approvals;
        bytes guardiansSignatures;
        bytes securityCouncilSignatures;
        bytes zkFoundationSignatures;
    }

    /// @notice Emits the ONE emergency proposal carrying every governance call of a prepared package.
    /// @param _protocolUpgradeHandler The handler that executes the package's governance calls.
    /// @param _ecosystemToml The merged package (`upgrade-envs/<version>/output/<env>/ecosystem.toml`).
    function run(address _protocolUpgradeHandler, string memory _ecosystemToml) external view {
        IProtocolUpgradeHandler.Call[] memory calls = loadGovernanceCalls(_ecosystemToml);
        require(calls.length != 0, "the package carries no governance calls");
        requireZeroTimerDelay(calls);
        _print(buildEmergencyProposal(IProtocolUpgradeHandler(_protocolUpgradeHandler), calls), _ecosystemToml);
    }

    /// @notice Every governance call of a prepared package, in execution order: each entry of its
    ///         `[governance_calls]` table is an `abi.encode(Call[])`, and the entries are taken in key
    ///         order (`stage0_calls`, `stage1_calls`, `stage2_calls` today) and concatenated.
    /// @param _ecosystemToml The merged package.
    function loadGovernanceCalls(
        string memory _ecosystemToml
    ) public view returns (IProtocolUpgradeHandler.Call[] memory calls) {
        string memory toml = vm.readFile(_ecosystemToml);
        string[] memory keys = _sortedKeys(vm.parseTomlKeys(toml, ".governance_calls"));
        IProtocolUpgradeHandler.Call[][] memory lists = new IProtocolUpgradeHandler.Call[][](keys.length);
        uint256 total;
        for (uint256 i = 0; i < keys.length; ++i) {
            bytes memory encoded = toml.readBytes(string.concat(".governance_calls.", keys[i]));
            if (encoded.length != 0) {
                lists[i] = abi.decode(encoded, (IProtocolUpgradeHandler.Call[]));
            }
            total += lists[i].length;
        }
        calls = new IProtocolUpgradeHandler.Call[](total);
        uint256 next;
        for (uint256 i = 0; i < lists.length; ++i) {
            for (uint256 j = 0; j < lists[i].length; ++j) {
                calls[next++] = lists[i][j];
            }
        }
    }

    /// @notice Refuses unless every `GovernanceUpgradeTimer` the calls start has a zero
    ///         `INITIAL_DELAY`: one proposal runs in one block, so a later call that checks the timer
    ///         (the coordinator's `stage1`, the bootstrap's `migrate()`) would revert after every
    ///         approval was collected. See "The upgrade timer and stage timing" in
    ///         {docs/upgrade-stage-lifecycle.md}.
    /// @param _calls The proposal's calls.
    function requireZeroTimerDelay(IProtocolUpgradeHandler.Call[] memory _calls) public view {
        for (uint256 i = 0; i < _calls.length; ++i) {
            address timer = startedTimer(_calls[i]);
            if (timer == address(0)) {
                continue;
            }
            uint256 delay = GovernanceUpgradeTimer(timer).INITIAL_DELAY();
            require(
                delay == 0,
                string.concat(
                    string.concat("upgrade timer ", vm.toString(timer), " holds the rest of the upgrade for "),
                    vm.toString(delay),
                    "s, so it cannot execute as one proposal: prepare it with a zero governance_upgrade_timer_initial_delay"
                )
            );
        }
    }

    /// @notice The `GovernanceUpgradeTimer` a governance call starts, or zero: the coordinator's
    ///         `stage0(operation)` starts the operation's timer, and the bootstrap edge calls
    ///         `startTimer()` on its own.
    /// @param _call One governance call.
    function startedTimer(IProtocolUpgradeHandler.Call memory _call) public view returns (address) {
        if (_call.data.length < 4) {
            return address(0);
        }
        bytes4 selector = bytes4(_call.data);
        if (selector == EcosystemUpgradeExecutor.stage0.selector) {
            return IEcosystemUpgradeOperation(abi.decode(Bytes.slice(_call.data, 4), (address))).timer();
        }
        if (selector == GovernanceUpgradeTimer.startTimer.selector) {
            return _call.target;
        }
        return address(0);
    }

    /// @notice Builds the proposal the handler's board executes `_calls` under, and the approvals
    ///         its signatures stand for. The first `EIP1271_THRESHOLD` members of each multisig
    ///         approve (its signature check wants them in member order), and the ZK Foundation Safe.
    /// @dev Every approving Safe must be a 1-of-1 Safe of the ZK Foundation Safe's owner: a marker
    ///      stands for that owner's approval and nothing else.
    /// @param _protocolUpgradeHandler The handler whose `emergencyUpgradeBoard()` executes the proposal.
    /// @param _calls The proposal's calls.
    function buildEmergencyProposal(
        IProtocolUpgradeHandler _protocolUpgradeHandler,
        IProtocolUpgradeHandler.Call[] memory _calls
    ) public view returns (EmergencyProposal memory proposal) {
        IEmergencyUpgrageBoard board = IEmergencyUpgrageBoard(_protocolUpgradeHandler.emergencyUpgradeBoard());
        IMultisig guardians = IMultisig(board.GUARDIANS());
        IMultisig securityCouncil = IMultisig(board.SECURITY_COUNCIL());
        address zkFoundation = board.ZK_FOUNDATION_SAFE();
        uint256 guardiansThreshold = guardians.EIP1271_THRESHOLD();

        proposal.board = board;
        proposal.owner = ISafe(zkFoundation).getOwners()[0];
        proposal.calls = _calls;
        proposal.id = proposalId(board, _calls);
        proposal.approvals = new SafeApproval[](guardiansThreshold + securityCouncil.EIP1271_THRESHOLD() + 1);

        proposal.guardiansSignatures = _approveMembers({
            _proposal: proposal,
            _multisig: guardians,
            _typehash: EXECUTE_EMERGENCY_UPGRADE_GUARDIANS_TYPEHASH,
            _firstApproval: 0,
            _label: "GUARDIANS"
        });
        proposal.securityCouncilSignatures = _approveMembers({
            _proposal: proposal,
            _multisig: securityCouncil,
            _typehash: EXECUTE_EMERGENCY_UPGRADE_SECURITY_COUNCIL_TYPEHASH,
            _firstApproval: guardiansThreshold,
            _label: "SECURITY_COUNCIL"
        });
        proposal.approvals[proposal.approvals.length - 1] = _approval({
            _owner: proposal.owner,
            _safe: zkFoundation,
            _digest: boardDigest(board, EXECUTE_EMERGENCY_UPGRADE_ZK_FOUNDATION_TYPEHASH, proposal.id),
            _signer: "ZK_FOUNDATION"
        });
        proposal.zkFoundationSignatures = _marker(proposal.owner);
    }

    /// @notice The id the handler records a proposal of `_calls` executed by `_board` under.
    /// @param _board The board that executes the proposal.
    /// @param _calls The proposal's calls.
    function proposalId(
        IEmergencyUpgrageBoard _board,
        IProtocolUpgradeHandler.Call[] memory _calls
    ) public pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    IProtocolUpgradeHandler.UpgradeProposal({
                        calls: _calls,
                        executor: address(_board),
                        salt: EMERGENCY_UPGRADE_SALT
                    })
                )
            );
    }

    /// @notice The EIP-712 digest one of the board's three signers approves for proposal `_id`.
    /// @param _board The board that checks the signatures.
    /// @param _typehash The signer's `ExecuteEmergencyUpgrade*` typehash.
    /// @param _id The proposal id.
    function boardDigest(IEmergencyUpgrageBoard _board, bytes32 _typehash, bytes32 _id) public view returns (bytes32) {
        return
            EIP712Utils.buildDigest(
                EIP712Utils.buildDomainHash(address(_board), "EmergencyUpgradeBoard", "1"),
                keccak256(abi.encode(_typehash, _id))
            );
    }

    /// @notice The board call that executes `_proposal` once every approval has landed.
    /// @param _proposal The proposal.
    function executeCalldata(EmergencyProposal memory _proposal) public pure returns (bytes memory) {
        return
            abi.encodeCall(
                IEmergencyUpgrageBoard.executeEmergencyUpgrade,
                (
                    _proposal.calls,
                    EMERGENCY_UPGRADE_SALT,
                    _proposal.guardiansSignatures,
                    _proposal.securityCouncilSignatures,
                    _proposal.zkFoundationSignatures
                )
            );
    }

    function _print(EmergencyProposal memory _proposal, string memory _title) internal pure {
        console2.log("================ EMERGENCY UPGRADE %s ================", _title);
        console2.log("Proposal id:");
        console2.logBytes32(_proposal.id);
        console2.log("Calls in proposal:", _proposal.calls.length);
        console2.log("Owner EOA that must send EVERY approveHash tx below:", _proposal.owner);
        console2.log("");
        console2.log("---- STEP 1: approveHash txs (send each from the owner EOA) ----");
        for (uint256 i = 0; i < _proposal.approvals.length; ++i) {
            SafeApproval memory approval = _proposal.approvals[i];
            console2.log("[%s] To (Safe):", approval.signer);
            console2.log("   ", approval.safe);
            console2.log("    Data (approveHash):");
            console2.logBytes(abi.encodeCall(ISafe.approveHash, (approval.safeMessageHash)));
        }
        console2.log("");
        console2.log("---- STEP 2: execute tx (send LAST, from any funded account) ----");
        console2.log("To  (EmergencyUpgradeBoard):", address(_proposal.board));
        console2.log("Value: 0");
        console2.log("Data:");
        console2.logBytes(executeCalldata(_proposal));
    }

    /// @return signatures The `abi.encode(members, markers)` the multisig's `isValidSignature` takes.
    function _approveMembers(
        EmergencyProposal memory _proposal,
        IMultisig _multisig,
        bytes32 _typehash,
        uint256 _firstApproval,
        string memory _label
    ) private view returns (bytes memory signatures) {
        bytes32 digest = boardDigest(_proposal.board, _typehash, _proposal.id);
        uint256 threshold = _multisig.EIP1271_THRESHOLD();
        address[] memory members = new address[](threshold);
        bytes[] memory markers = new bytes[](threshold);
        for (uint256 i = 0; i < threshold; ++i) {
            members[i] = _multisig.members(i);
            _proposal.approvals[_firstApproval + i] = _approval({
                _owner: _proposal.owner,
                _safe: members[i],
                _digest: digest,
                _signer: string.concat(_label, " ", vm.toString(i + 1))
            });
            markers[i] = _marker(_proposal.owner);
        }
        signatures = abi.encode(members, markers);
    }

    function _approval(
        address _owner,
        address _safe,
        bytes32 _digest,
        string memory _signer
    ) private view returns (SafeApproval memory) {
        address[] memory owners = ISafe(_safe).getOwners();
        require(
            owners.length == 1 && owners[0] == _owner && ISafe(_safe).getThreshold() == 1,
            string.concat(
                string.concat(_signer, " Safe ", vm.toString(_safe)),
                " is not a 1-of-1 Safe of ",
                vm.toString(_owner)
            )
        );
        return
            SafeApproval({
                signer: _signer,
                safe: _safe,
                safeMessageHash: ISafe(_safe).getMessageHash(abi.encode(_digest))
            });
    }

    function _sortedKeys(string[] memory _keys) private pure returns (string[] memory) {
        for (uint256 i = 1; i < _keys.length; ++i) {
            string memory current = _keys[i];
            uint256 j = i;
            while (j > 0 && _precedes(current, _keys[j - 1])) {
                _keys[j] = _keys[j - 1];
                --j;
            }
            _keys[j] = current;
        }
        return _keys;
    }

    function _precedes(string memory _a, string memory _b) private pure returns (bool) {
        bytes memory a = bytes(_a);
        bytes memory b = bytes(_b);
        uint256 length = a.length < b.length ? a.length : b.length;
        for (uint256 i = 0; i < length; ++i) {
            if (a[i] != b[i]) {
                return a[i] < b[i];
            }
        }
        return a.length < b.length;
    }

    /// @dev Gnosis Safe "pre-approved hash" signature: r = owner, s = 0, v = 1.
    function _marker(address _owner) private pure returns (bytes memory) {
        return abi.encodePacked(bytes32(uint256(uint160(_owner))), bytes32(0), uint8(1));
    }
}
