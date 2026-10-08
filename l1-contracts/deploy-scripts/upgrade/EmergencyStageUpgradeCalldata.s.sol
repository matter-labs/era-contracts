// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {EIP712Utils} from "../utils/EIP712Utils.sol";
import {
    EXECUTE_EMERGENCY_UPGRADE_GUARDIANS_TYPEHASH,
    EXECUTE_EMERGENCY_UPGRADE_SECURITY_COUNCIL_TYPEHASH,
    EXECUTE_EMERGENCY_UPGRADE_ZK_FOUNDATION_TYPEHASH
} from "../utils/Utils.sol";
import {IProtocolUpgradeHandler} from "../interfaces/IProtocolUpgradeHandler.sol";
import {IEmergencyUpgrageBoard} from "../interfaces/IEmergencyUpgrageBoard.sol";
import {Script, console2} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

interface IMultisigT {
    function members(uint256) external view returns (address);
    function EIP1271_THRESHOLD() external view returns (uint256);
}

interface ISafeMsg {
    function getMessageHash(bytes memory _message) external view returns (bytes32);
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
}

interface IOwnableT {
    function owner() external view returns (address);
}

interface IEmergencyUpgradeBoardHandlerT {
    function PROTOCOL_UPGRADE_HANDLER() external view returns (address);
}

/// @notice Emits ALL calldata to execute an emergency upgrade through an ecosystem's Emergency Upgrade
/// Board WITHOUT any private key or off-chain signing. Every member of the Guardians / Security Council
/// boards and the ZK Foundation is a 1-of-1 Gnosis Safe owned by a single EOA, so the owner can
/// satisfy the board's EIP-1271 checks by pre-approving each Safe message hash on-chain
/// (`approveHash`) and then submitting the board call with Gnosis "approved hash" signature markers
/// (r = owner, s = 0, v = 1) — which contain no signature.
///
/// Output = a list of `approveHash(...)` txs (To + Data) the owner sends from MetaMask, followed by one
/// `executeEmergencyUpgrade(...)` tx (To + Data). Nothing here needs a key; everything is read on-chain.
///
/// Which ecosystem: the env's permanent values (`upgrade-envs/permanent-values/<env>.toml`) name its
/// bridgehub, whose owner is the ProtocolUpgradeHandler. The handler names the Emergency Upgrade Board,
/// the Guardians and the Security Council; the board names the ZK Foundation Safe, whose owner is the
/// owner of every member Safe. Nothing is specific to one env:
///   forge script deploy-scripts/upgrade/EmergencyStageUpgradeCalldata.s.sol:EmergencyStageUpgradeCalldata \
///     --sig 'printEmergencyBoard(string)' /upgrade-envs/permanent-values/testnet.toml --rpc-url $SEPOLIA_RPC
///   ... --sig 'emergencyUpgradeAllStages(string,string,string)' <permanent values> <ecosystem.toml> <out.json>
///
/// The older entry points target stage: `runStage0()` / `runStage1()` / `runStage2()` for the v31 interopB
/// stage upgrade (run stage 1 >= 1200s after stage 0, the GovernanceUpgradeTimer delay) and
/// `runV33CompilerStage()` for the v0.33.0 compiler upgrade. They only print.
contract EmergencyStageUpgradeCalldata is Script {
    using stdToml for string;

    /// @notice Stage's ProtocolUpgradeHandler, for the stage-only scripts that inherit this one. The entry
    /// points here derive the handler from the env's bridgehub instead.
    IProtocolUpgradeHandler constant PUH = IProtocolUpgradeHandler(0x8f08627524aeD610192132A425D6b9C32a1727EF);
    /// @notice Stage's permanent values, for the stage-only entry points.
    string constant STAGE_PERMANENT_VALUES = "/upgrade-envs/permanent-values/stage.toml";
    string constant TOML = "/upgrade-envs/v0.31.0-interopB/output/stage/ecosystem.toml";
    /// @notice The v0.33.0 compiler-only stage upgrade (`upgrade-envs/v0.33.0-compiler/`).
    string constant V33_COMPILER_TOML = "/upgrade-envs/v0.33.0-compiler/output/stage/ecosystem.toml";
    bytes32 constant SALT = bytes32(0);
    /// @notice `core_contracts.governance_kind` of an env whose bridgehub is owned by a ProtocolUpgradeHandler.
    string constant PUH_GOVERNANCE_KIND = "puh";
    /// @notice Governance stages in an `ecosystem.toml` (`governance_calls.stage{0,1,2}_calls`).
    uint256 constant GOVERNANCE_STAGE_COUNT = 3;

    /// @notice The emergency path of one ecosystem, as read on-chain.
    struct EmergencyBoard {
        address handler;
        address board;
        address guardians;
        address securityCouncil;
        address zkFoundationSafe;
        /// @dev Owner of the ZK Foundation Safe, and (checked per used Safe) of every member Safe.
        address owner;
    }

    /// @notice One transaction the owner sends, in order.
    struct EmergencyTx {
        string label;
        address to;
        bytes data;
    }

    function runStage0() external view {
        _emit(0);
    }

    function runStage1() external view {
        _emit(1);
    }

    function runStage2() external view {
        _emit(2);
    }

    /// @notice The v0.33.0 compiler-only stage upgrade as ONE emergency proposal: stages 0, 1 and 2
    /// in order (pauseMigration; setNewVersionUpgrade + setChainCreationParams; unpauseMigration).
    /// It has no upgrade timer between stages, so executing them atomically is equivalent and needs
    /// one round of approvals instead of three.
    function runV33CompilerStage() external view {
        _emitForCalls(_loadAllStages(V33_COMPILER_TOML), "V0.33.0 COMPILER (STAGES 0-2)");
    }

    /// @notice Governance stages 0, 1 and 2 of `_ecosystemToml` as ONE emergency proposal on the ecosystem of
    /// `_permanentValues`, written to `_outputJson` (the `emergency-upgrade-board.json` layout that
    /// `protocol_ops dev execution-runbook` renders as EXECUTE.md). Only for upgrades with no timer between
    /// their stages. Paths are relative to the l1-contracts root, starting with `/`.
    function emergencyUpgradeAllStages(
        string memory _permanentValues,
        string memory _ecosystemToml,
        string memory _outputJson
    ) external {
        EmergencyBoard memory board = _resolveBoard(_permanentValues);
        EmergencyTx[] memory txs = _buildProposal(board, _loadAllStages(_ecosystemToml));
        _logProposal(board, txs, "ALL GOVERNANCE STAGES");
        string memory path = string.concat(vm.projectRoot(), _outputJson);
        vm.writeFile(path, _proposalJson(board, txs, _ecosystemToml));
        console2.log("Written to", path);
    }

    /// @notice Read-only: prints the emergency path of the ecosystem of `_permanentValues` (handler, board,
    /// the members whose approvals the board needs, and their owner) and checks that the owner can approve
    /// on every one of them. Builds no proposal.
    function printEmergencyBoard(string memory _permanentValues) external view {
        EmergencyBoard memory board = _resolveBoard(_permanentValues);
        console2.log("ProtocolUpgradeHandler:", board.handler);
        console2.log("Emergency Upgrade Board:", board.board);
        console2.log("Owner of every approving Safe:", board.owner);
        address[] memory guardians = _approvingMembers(board.guardians, board.owner);
        address[] memory council = _approvingMembers(board.securityCouncil, board.owner);
        _requireOneOfOneSafe(board.zkFoundationSafe, board.owner);
        _logMembers("Guardians", board.guardians, guardians);
        _logMembers("Security Council", board.securityCouncil, council);
        console2.log("ZK Foundation Safe:", board.zkFoundationSafe);
        console2.log("Approving Safes (approveHash txs per proposal):", guardians.length + council.length + 1);
    }

    /// @dev Copies `_from` into `_into` starting at `_at`; returns the next free index.
    function _appendCalls(
        IProtocolUpgradeHandler.Call[] memory _into,
        uint256 _at,
        IProtocolUpgradeHandler.Call[] memory _from
    ) internal pure returns (uint256) {
        uint256 count = _from.length;
        for (uint256 i = 0; i < count; ++i) {
            _into[_at + i] = _from[i];
        }
        return _at + count;
    }

    function _emit(uint256 _stage) internal view {
        _emitForCalls(_loadCalls(_stage), string.concat("STAGE ", vm.toString(_stage)));
    }

    /// @notice Prints the approveHash + execute calldata for an arbitrary emergency-upgrade proposal on stage.
    /// @dev Shared by the stage runners and by one-off emergency upgrades (e.g. a single ProxyAdmin.upgrade).
    function _emitForCalls(IProtocolUpgradeHandler.Call[] memory _calls, string memory _title) internal view {
        EmergencyBoard memory board = _resolveBoard(STAGE_PERMANENT_VALUES);
        _logProposal(board, _buildProposal(board, _calls), _title);
    }

    /// @notice The emergency path of the ecosystem whose permanent values are at `_permanentValues`.
    function _resolveBoard(string memory _permanentValues) internal view returns (EmergencyBoard memory board) {
        string memory toml = vm.readFile(string.concat(vm.projectRoot(), _permanentValues));
        require(
            keccak256(bytes(toml.readString("$.core_contracts.governance_kind"))) ==
                keccak256(bytes(PUH_GOVERNANCE_KIND)),
            "env is not governed by a ProtocolUpgradeHandler"
        );
        board.handler = IOwnableT(toml.readAddress("$.core_contracts.bridgehub_proxy_addr")).owner();
        IProtocolUpgradeHandler handler = IProtocolUpgradeHandler(board.handler);
        board.board = handler.emergencyUpgradeBoard();
        board.guardians = handler.guardians();
        board.securityCouncil = handler.securityCouncil();
        IEmergencyUpgrageBoard emergencyBoard = IEmergencyUpgrageBoard(board.board);
        require(
            IEmergencyUpgradeBoardHandlerT(board.board).PROTOCOL_UPGRADE_HANDLER() == board.handler,
            "board serves another handler"
        );
        require(emergencyBoard.GUARDIANS() == board.guardians, "board and handler name different Guardians");
        require(
            emergencyBoard.SECURITY_COUNCIL() == board.securityCouncil,
            "board and handler name different Security Councils"
        );
        board.zkFoundationSafe = emergencyBoard.ZK_FOUNDATION_SAFE();
        board.owner = ISafeMsg(board.zkFoundationSafe).getOwners()[0];
    }

    /// @notice The approveHash txs and the final executeEmergencyUpgrade tx for `_calls`, all sent by the owner.
    function _buildProposal(
        EmergencyBoard memory _board,
        IProtocolUpgradeHandler.Call[] memory _calls
    ) internal view returns (EmergencyTx[] memory txs) {
        bytes32 id = keccak256(
            abi.encode(IProtocolUpgradeHandler.UpgradeProposal({calls: _calls, executor: _board.board, salt: SALT}))
        );
        bytes32 dom = EIP712Utils.buildDomainHash(_board.board, "EmergencyUpgradeBoard", "1");

        address[] memory gMembers = _approvingMembers(_board.guardians, _board.owner);
        address[] memory scMembers = _approvingMembers(_board.securityCouncil, _board.owner);
        _requireOneOfOneSafe(_board.zkFoundationSafe, _board.owner);
        txs = new EmergencyTx[](gMembers.length + scMembers.length + 2);

        _approveSet(txs, 0, gMembers, dom, EXECUTE_EMERGENCY_UPGRADE_GUARDIANS_TYPEHASH, id, "GUARDIANS");
        _approveSet(
            txs,
            gMembers.length,
            scMembers,
            dom,
            EXECUTE_EMERGENCY_UPGRADE_SECURITY_COUNCIL_TYPEHASH,
            id,
            "SECURITY_COUNCIL"
        );
        uint256 zkIndex = gMembers.length + scMembers.length;
        txs[zkIndex] = EmergencyTx({
            label: "ZK_FOUNDATION",
            to: _board.zkFoundationSafe,
            data: _approveHashCall(_board.zkFoundationSafe, dom, EXECUTE_EMERGENCY_UPGRADE_ZK_FOUNDATION_TYPEHASH, id)
        });
        txs[zkIndex + 1] = EmergencyTx({
            label: "EXECUTE",
            to: _board.board,
            data: _executeCall(_board.owner, _calls, gMembers, scMembers)
        });
    }

    /// @dev `executeEmergencyUpgrade` with an approved-hash marker of `_owner` for every approving member.
    function _executeCall(
        address _owner,
        IProtocolUpgradeHandler.Call[] memory _calls,
        address[] memory _guardians,
        address[] memory _council
    ) internal pure returns (bytes memory) {
        return
            abi.encodeCall(
                IEmergencyUpgrageBoard.executeEmergencyUpgrade,
                (
                    _calls,
                    SALT,
                    abi.encode(_guardians, _markers(_owner, _guardians.length)),
                    abi.encode(_council, _markers(_owner, _council.length)),
                    _marker(_owner)
                )
            );
    }

    /// @dev Fills `_txs[_at..]` with one approveHash tx per member.
    function _approveSet(
        EmergencyTx[] memory _txs,
        uint256 _at,
        address[] memory _members,
        bytes32 _dom,
        bytes32 _typehash,
        bytes32 _id,
        string memory _label
    ) internal view {
        for (uint256 i = 0; i < _members.length; i++) {
            _txs[_at + i] = EmergencyTx({
                label: string.concat(_label, " ", vm.toString(i + 1)),
                to: _members[i],
                data: _approveHashCall(_members[i], _dom, _typehash, _id)
            });
        }
    }

    /// @dev `approveHash` of the Safe message hash of the board digest for `_typehash`.
    function _approveHashCall(
        address _safe,
        bytes32 _dom,
        bytes32 _typehash,
        bytes32 _id
    ) internal view returns (bytes memory) {
        bytes32 boardDigest = EIP712Utils.buildDigest(_dom, keccak256(abi.encode(_typehash, _id)));
        bytes32 safeMsgHash = ISafeMsg(_safe).getMessageHash(abi.encode(boardDigest));
        return abi.encodeWithSignature("approveHash(bytes32)", safeMsgHash);
    }

    /// @dev The FIRST `EIP1271_THRESHOLD` members in member order (checkSignatures requires ascending member
    /// order), each checked to be a 1-of-1 Safe of `_owner`: the approved-hash markers are only valid then.
    function _approvingMembers(address _multisig, address _owner) internal view returns (address[] memory members) {
        uint256 threshold = IMultisigT(_multisig).EIP1271_THRESHOLD();
        members = new address[](threshold);
        for (uint256 i = 0; i < threshold; i++) {
            members[i] = IMultisigT(_multisig).members(i);
            _requireOneOfOneSafe(members[i], _owner);
        }
    }

    function _requireOneOfOneSafe(address _safe, address _owner) internal view {
        address[] memory owners = ISafeMsg(_safe).getOwners();
        require(
            owners.length == 1 && owners[0] == _owner && ISafeMsg(_safe).getThreshold() == 1,
            string.concat("not a 1-of-1 Safe of the owner: ", vm.toString(_safe))
        );
    }

    function _loadCalls(uint256 _stage) internal view returns (IProtocolUpgradeHandler.Call[] memory) {
        return _loadCallsFrom(TOML, _stage);
    }

    /// @dev Governance stages 0, 1 and 2 of `_tomlPath`, in order, as one call list.
    function _loadAllStages(string memory _tomlPath) internal view returns (IProtocolUpgradeHandler.Call[] memory) {
        IProtocolUpgradeHandler.Call[][] memory stages = new IProtocolUpgradeHandler.Call[][](GOVERNANCE_STAGE_COUNT);
        uint256 total = 0;
        for (uint256 stage = 0; stage < GOVERNANCE_STAGE_COUNT; ++stage) {
            stages[stage] = _loadCallsFrom(_tomlPath, stage);
            total += stages[stage].length;
        }
        IProtocolUpgradeHandler.Call[] memory calls = new IProtocolUpgradeHandler.Call[](total);
        uint256 next = 0;
        for (uint256 stage = 0; stage < GOVERNANCE_STAGE_COUNT; ++stage) {
            next = _appendCalls(calls, next, stages[stage]);
        }
        return calls;
    }

    function _loadCallsFrom(
        string memory _tomlPath,
        uint256 _stage
    ) internal view returns (IProtocolUpgradeHandler.Call[] memory) {
        string memory toml = vm.readFile(string.concat(vm.projectRoot(), _tomlPath));
        bytes memory encodedCalls = toml.readBytes(
            string.concat(".governance_calls.stage", vm.toString(_stage), "_calls")
        );
        return abi.decode(encodedCalls, (IProtocolUpgradeHandler.Call[]));
    }

    function _logProposal(EmergencyBoard memory _board, EmergencyTx[] memory _txs, string memory _title) internal pure {
        console2.log("================ EMERGENCY UPGRADE %s ================", _title);
        console2.log("Owner EOA that must send EVERY tx below (your MetaMask account):", _board.owner);
        console2.log("");
        console2.log("---- STEP 1: approveHash txs (send each from the owner EOA) ----");
        uint256 last = _txs.length - 1;
        for (uint256 i = 0; i < last; i++) {
            console2.log("[%s] To (member Safe):", _txs[i].label);
            console2.log("   ", _txs[i].to);
            console2.log("    Data (approveHash):");
            console2.logBytes(_txs[i].data);
        }
        console2.log("");
        console2.log("---- STEP 2: execute tx (send LAST) ----");
        console2.log("To  (EmergencyUpgradeBoard):", _txs[last].to);
        console2.log("Value: 0");
        console2.log("Data:");
        console2.logBytes(_txs[last].data);
    }

    function _logMembers(string memory _name, address _multisig, address[] memory _members) internal pure {
        console2.log("%s %s: the first %s members approve", _name, _multisig, _members.length);
        for (uint256 i = 0; i < _members.length; i++) {
            console2.log("   ", _members[i]);
        }
    }

    /// @dev `emergency-upgrade-board.json`, formatted the way prettier formats it.
    function _proposalJson(
        EmergencyBoard memory _board,
        EmergencyTx[] memory _txs,
        string memory _ecosystemToml
    ) internal view returns (string memory json) {
        json = string.concat(
            "{\n",
            '  "_comment": "Governance stages 0-2 of ',
            _ecosystemToml,
            " as ONE emergency proposal, generated by EmergencyStageUpgradeCalldata.s.sol emergencyUpgradeAllStages(). ",
            'Send every tx from `owner`, in order.",\n',
            '  "emergency_upgrade_board": "',
            vm.toString(_board.board),
            '",\n',
            '  "protocol_upgrade_handler": "',
            vm.toString(_board.handler),
            '",\n'
        );
        json = string.concat(
            json,
            '  "owner": "',
            vm.toString(_board.owner),
            '",\n',
            '  "chain_id": ',
            vm.toString(block.chainid),
            ",\n",
            '  "transactions": [\n'
        );
        for (uint256 i = 0; i < _txs.length; i++) {
            json = string.concat(
                json,
                "    {\n",
                '      "step": ',
                vm.toString(i + 1),
                ",\n",
                '      "label": "',
                _txs[i].label,
                '",\n',
                '      "from": "',
                vm.toString(_board.owner),
                '",\n'
            );
            json = string.concat(
                json,
                '      "to": "',
                vm.toString(_txs[i].to),
                '",\n',
                '      "data": "',
                vm.toString(_txs[i].data),
                '"\n',
                i + 1 == _txs.length ? "    }\n" : "    },\n"
            );
        }
        json = string.concat(json, "  ]\n}\n");
    }

    /// @dev Gnosis Safe "pre-approved hash" signature marker: r = owner, s = 0, v = 1. No key involved.
    function _marker(address _owner) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes32(uint256(uint160(_owner))), bytes32(0), uint8(1));
    }

    function _markers(address _owner, uint256 _count) internal pure returns (bytes[] memory markers) {
        markers = new bytes[](_count);
        for (uint256 i = 0; i < _count; i++) {
            markers[i] = _marker(_owner);
        }
    }
}
