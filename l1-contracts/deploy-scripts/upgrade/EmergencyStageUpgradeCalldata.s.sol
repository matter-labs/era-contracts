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
}

/// @notice Emits ALL calldata to execute one stage of the v31 interopB STAGE emergency upgrade
/// WITHOUT any private key or off-chain signing. Every member of the Guardians / Security Council
/// boards and the ZK Foundation is a 1-of-1 Gnosis Safe owned by a single EOA, so the owner can
/// satisfy the board's EIP-1271 checks by pre-approving each Safe message hash on-chain
/// (`approveHash`) and then submitting the board call with Gnosis "approved hash" signature markers
/// (r = owner, s = 0, v = 1) — which contain no signature.
///
/// Output per stage = a list of `approveHash(...)` txs (To + Data) the owner sends from MetaMask,
/// followed by one `executeEmergencyUpgrade(...)` tx (To + Data). Nothing here needs a key; run it
/// read-only against a Sepolia RPC (it only reads members/thresholds/message hashes):
///   forge script deploy-scripts/upgrade/EmergencyStageUpgradeCalldata.s.sol:EmergencyStageUpgradeCalldata \
///     --sig 'runStage0()' --rpc-url $SEPOLIA_RPC
/// then `runStage1()` (after >= 1200s, the GovernanceUpgradeTimer delay) and `runStage2()`.
contract EmergencyStageUpgradeCalldata is Script {
    using stdToml for string;

    IProtocolUpgradeHandler constant PUH = IProtocolUpgradeHandler(0x8f08627524aeD610192132A425D6b9C32a1727EF);
    string constant TOML = "upgrade-envs/v0.31.0-interopB/output/stage/ecosystem.toml";
    bytes32 constant SALT = bytes32(0);

    function runStage0() external view {
        _emit(0);
    }

    function runStage1() external view {
        _emit(1);
    }

    function runStage2() external view {
        _emit(2);
    }

    function _emit(uint256 _stage) internal view {
        IProtocolUpgradeHandler.Call[] memory calls = _loadCalls(_stage);
        IEmergencyUpgrageBoard board = IEmergencyUpgrageBoard(PUH.emergencyUpgradeBoard());
        address owner = ISafeMsg(board.ZK_FOUNDATION_SAFE()).getOwners()[0];

        bytes32 id = keccak256(
            abi.encode(IProtocolUpgradeHandler.UpgradeProposal({calls: calls, executor: address(board), salt: SALT}))
        );
        bytes32 dom = EIP712Utils.buildDomainHash(address(board), "EmergencyUpgradeBoard", "1");

        console2.log("================ EMERGENCY UPGRADE STAGE %s ================", _stage);
        console2.log("Calls in proposal:", calls.length);
        console2.log("Owner EOA that must send EVERY tx below (your MetaMask account):", owner);
        console2.log("");
        console2.log("---- STEP 1: approveHash txs (send each from the owner EOA) ----");

        (address[] memory gMembers, bytes[] memory gSigs) = _approveSet(
            owner, board.GUARDIANS(), dom, EXECUTE_EMERGENCY_UPGRADE_GUARDIANS_TYPEHASH, id, "GUARDIANS"
        );
        (address[] memory scMembers, bytes[] memory scSigs) = _approveSet(
            owner, board.SECURITY_COUNCIL(), dom, EXECUTE_EMERGENCY_UPGRADE_SECURITY_COUNCIL_TYPEHASH, id, "SECURITY_COUNCIL"
        );
        bytes memory zkSig = _approveZk(owner, board.ZK_FOUNDATION_SAFE(), dom, id);

        bytes memory execData = abi.encodeCall(
            IEmergencyUpgrageBoard.executeEmergencyUpgrade,
            (calls, SALT, abi.encode(gMembers, gSigs), abi.encode(scMembers, scSigs), zkSig)
        );

        console2.log("");
        console2.log("---- STEP 2: execute tx (send LAST, from any funded account) ----");
        console2.log("To  (EmergencyUpgradeBoard):", address(board));
        console2.log("Value: 0");
        console2.log("Data:");
        console2.logBytes(execData);
    }

    function _loadCalls(uint256 _stage) internal view returns (IProtocolUpgradeHandler.Call[] memory) {
        string memory toml = vm.readFile(TOML);
        bytes memory encodedCalls = toml.readBytes(
            string.concat(".governance_calls.stage", vm.toString(_stage), "_calls")
        );
        IProtocolUpgradeHandler.Call[] memory calls = abi.decode(encodedCalls, (IProtocolUpgradeHandler.Call[]));
        if (_stage != 1) {
            return calls;
        }

        // Emergency-path fixup: PUH.executeEmergencyUpgrade runs a built-in unfreeze/unpause pre-step
        // that calls ChainAssetHandler.unpauseMigration(), clearing the pause set in stage 0. stage 1's
        // checkMigrationsPaused() would then revert with MigrationsNotPaused(). Re-assert the pause as the
        // first stage-1 call so it holds through stage-1 validation. (The normal governance path has no
        // such auto-unpause; this is specific to executing via the EmergencyUpgradeBoard.)
        address cah = toml.readAddress(".core.upgrade_addresses.bridgehub.chain_asset_handler_proxy_addr");
        IProtocolUpgradeHandler.Call[] memory withPause = new IProtocolUpgradeHandler.Call[](calls.length + 1);
        withPause[0] = IProtocolUpgradeHandler.Call({
            target: cah,
            value: 0,
            data: abi.encodeWithSignature("pauseMigration()")
        });
        for (uint256 i = 0; i < calls.length; i++) {
            withPause[i + 1] = calls[i];
        }
        return withPause;
    }

    /// @dev Approves `threshold` member-Safe message hashes (printing each approveHash tx) and returns
    /// the matching (members, approved-hash-markers) to embed in the board call. Uses the FIRST
    /// `threshold` members in member order (checkSignatures requires ascending member order).
    function _approveSet(
        address _owner,
        address _multisig,
        bytes32 _dom,
        bytes32 _typehash,
        bytes32 _id,
        string memory _label
    ) internal view returns (address[] memory members, bytes[] memory sigs) {
        uint256 threshold = IMultisigT(_multisig).EIP1271_THRESHOLD();
        bytes32 boardDigest = EIP712Utils.buildDigest(_dom, keccak256(abi.encode(_typehash, _id)));
        members = new address[](threshold);
        sigs = new bytes[](threshold);
        for (uint256 i = 0; i < threshold; i++) {
            members[i] = IMultisigT(_multisig).members(i);
            bytes32 safeMsgHash = ISafeMsg(members[i]).getMessageHash(abi.encode(boardDigest));
            console2.log("[%s %s] To (member Safe):", _label, i + 1);
            console2.log("   ", members[i]);
            console2.log("    Data (approveHash):");
            console2.logBytes(abi.encodeWithSignature("approveHash(bytes32)", safeMsgHash));
            sigs[i] = _marker(_owner);
        }
    }

    function _approveZk(address _owner, address _zk, bytes32 _dom, bytes32 _id) internal view returns (bytes memory) {
        bytes32 boardDigest = EIP712Utils.buildDigest(
            _dom, keccak256(abi.encode(EXECUTE_EMERGENCY_UPGRADE_ZK_FOUNDATION_TYPEHASH, _id))
        );
        bytes32 safeMsgHash = ISafeMsg(_zk).getMessageHash(abi.encode(boardDigest));
        console2.log("[ZK_FOUNDATION] To (Safe):", _zk);
        console2.log("    Data (approveHash):");
        console2.logBytes(abi.encodeWithSignature("approveHash(bytes32)", safeMsgHash));
        return _marker(_owner);
    }

    /// @dev Gnosis Safe "pre-approved hash" signature marker: r = owner, s = 0, v = 1. No key involved.
    function _marker(address _owner) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes32(uint256(uint160(_owner))), bytes32(0), uint8(1));
    }
}
