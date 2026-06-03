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

interface IMultisigT {
    function members(uint256) external view returns (address);
    function EIP1271_THRESHOLD() external view returns (uint256);
}

interface ISafeApprove {
    function getMessageHash(bytes memory _message) external view returns (bytes32);
    function approveHash(bytes32 _hashToApprove) external;
    function getOwners() external view returns (address[] memory);
}

/// @notice FORK-ONLY proof that the emergency upgrade can be executed with ZERO off-chain signing:
/// the single owner EOA pre-approves the per-member Safe message hashes on-chain (`approveHash`),
/// then the board call passes Gnosis-Safe "approved hash" signature markers (r = owner, s = 0, v = 1).
/// Uses an EMPTY Call[] so it isolates the signature path from the real upgrade calls / prerequisites.
/// Run against a Sepolia fork (vm.prank simulates the owner; no key needed):
///   forge script deploy-scripts/upgrade/VerifyEmergencyApproveHash.s.sol:VerifyEmergencyApproveHash \
///     --sig 'run()' --rpc-url $SEPOLIA_RPC -vvvv
contract VerifyEmergencyApproveHash is Script {
    IProtocolUpgradeHandler constant PUH = IProtocolUpgradeHandler(0x8f08627524aeD610192132A425D6b9C32a1727EF);
    uint256 constant GUARDIANS_SIZE = 8;
    uint256 constant SECURITY_COUNCIL_SIZE = 12;
    bytes32 constant SALT = bytes32(0);

    function run() external {
        IProtocolUpgradeHandler.Call[] memory calls = new IProtocolUpgradeHandler.Call[](0); // empty: isolate sig path

        IEmergencyUpgrageBoard board = IEmergencyUpgrageBoard(PUH.emergencyUpgradeBoard());
        bytes32 id = keccak256(
            abi.encode(IProtocolUpgradeHandler.UpgradeProposal({calls: calls, executor: address(board), salt: SALT}))
        );
        bytes32 dom = EIP712Utils.buildDomainHash(address(board), "EmergencyUpgradeBoard", "1");

        // The single owner of every member Safe (confirmed on-chain).
        address owner = ISafeApprove(board.ZK_FOUNDATION_SAFE()).getOwners()[0];
        console2.log("Owner EOA (must be your MetaMask account):", owner);

        bytes memory gSigs = _approveAndMark(owner, board.GUARDIANS(), dom, EXECUTE_EMERGENCY_UPGRADE_GUARDIANS_TYPEHASH, id);
        bytes memory scSigs = _approveAndMark(owner, board.SECURITY_COUNCIL(), dom, EXECUTE_EMERGENCY_UPGRADE_SECURITY_COUNCIL_TYPEHASH, id);
        bytes memory zkSig = _approveSingle(owner, board.ZK_FOUNDATION_SAFE(), dom, EXECUTE_EMERGENCY_UPGRADE_ZK_FOUNDATION_TYPEHASH, id);

        board.executeEmergencyUpgrade(calls, SALT, gSigs, scSigs, zkSig);
        console2.log("SUCCESS: board accepted approved-hash markers; emergency upgrade executed (empty calls).");
    }

    function _marker(address _owner) internal pure returns (bytes memory) {
        // Gnosis Safe "pre-approved hash" signature: r = owner address, s = 0, v = 1. No private key involved.
        return abi.encodePacked(bytes32(uint256(uint160(_owner))), bytes32(0), uint8(1));
    }

    function _approveAndMark(
        address _owner,
        address _multisig,
        bytes32 _dom,
        bytes32 _typehash,
        bytes32 _id
    ) internal returns (bytes memory) {
        uint256 size = IMultisigT(_multisig).EIP1271_THRESHOLD();
        bytes32 boardDigest = EIP712Utils.buildDigest(_dom, keccak256(abi.encode(_typehash, _id)));
        address[] memory members = new address[](size);
        bytes[] memory sigs = new bytes[](size);
        for (uint256 i = 0; i < size; i++) {
            members[i] = IMultisigT(_multisig).members(i);
            bytes32 safeMsgHash = ISafeApprove(members[i]).getMessageHash(abi.encode(boardDigest));
            vm.prank(_owner);
            ISafeApprove(members[i]).approveHash(safeMsgHash);
            sigs[i] = _marker(_owner);
        }
        return abi.encode(members, sigs);
    }

    function _approveSingle(
        address _owner,
        address _safe,
        bytes32 _dom,
        bytes32 _typehash,
        bytes32 _id
    ) internal returns (bytes memory) {
        bytes32 boardDigest = EIP712Utils.buildDigest(_dom, keccak256(abi.encode(_typehash, _id)));
        bytes32 safeMsgHash = ISafeApprove(_safe).getMessageHash(abi.encode(boardDigest));
        vm.prank(_owner);
        ISafeApprove(_safe).approveHash(safeMsgHash);
        return _marker(_owner);
    }
}
