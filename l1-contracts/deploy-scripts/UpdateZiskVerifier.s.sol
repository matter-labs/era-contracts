// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {ZiskVerifier} from "../contracts/state-transition/verifiers/ZiskVerifier.sol";
import {MultiProofVerifier} from "../contracts/state-transition/verifiers/MultiProofVerifier.sol";
import {IVerifier} from "../contracts/state-transition/chain-interfaces/IVerifier.sol";

/// @title Update ZiSK Verifier
/// @notice Deploys a new ZiskVerifier and updates the MultiProofVerifier to point to it.
///
/// @dev ZiSK verification keys are hardcoded in ZiskVerifier.sol bytecode:
///   - programVK: 4 x uint64 derived from the ROM Merkle root of the guest ELF
///   - rootCVadcopFinal: 4 x uint64 vadcop final root commitment
///   - VK_HASH: bytes32 matching server's ProvingVersion VK hash
///
/// These change whenever the ZiSK guest ELF binary changes (new features, bug fixes).
/// The ZiskSnarkPlonkVerifier circuit VK changes rarely (only on SNARK circuit upgrades).
///
/// Usage:
///   # 1. Update constants in ZiskVerifier.sol with new values, then:
///   forge script deploy-scripts/UpdateZiskVerifier.s.sol:UpdateZiskVerifier \
///     --rpc-url $RPC_URL \
///     --broadcast \
///     --private-key $OWNER_PK \
///     -vvv \
///     --sig "run(address)" $MULTI_PROOF_VERIFIER_ADDRESS
///
///   # Or dry-run first:
///   forge script deploy-scripts/UpdateZiskVerifier.s.sol:UpdateZiskVerifier \
///     --rpc-url $RPC_URL \
///     --sig "run(address)" $MULTI_PROOF_VERIFIER_ADDRESS
contract UpdateZiskVerifier is Script {
    function run(address multiProofVerifier) external {
        MultiProofVerifier mpv = MultiProofVerifier(multiProofVerifier);

        // Log current state
        address currentZisk = address(mpv.ziskVerifier());
        console2.log("MultiProofVerifier:", multiProofVerifier);
        console2.log("Current ZiSK verifier:", currentZisk);
        if (currentZisk != address(0)) {
            console2.log("Current VK hash:", uint256(IVerifier(currentZisk).verificationKeyHash()));
        }

        vm.startBroadcast();

        // Deploy new ZiskVerifier (with updated constants in bytecode)
        ZiskVerifier newVerifier = new ZiskVerifier();
        console2.log("New ZiskVerifier deployed at:", address(newVerifier));
        console2.log("New VK hash:", uint256(newVerifier.verificationKeyHash()));

        // Update the MultiProofVerifier to use the new ZiskVerifier
        mpv.setZiskVerifier(IVerifier(address(newVerifier)));
        console2.log("MultiProofVerifier updated to new ZiskVerifier");

        // Verify
        address updatedZisk = address(mpv.ziskVerifier());
        require(updatedZisk == address(newVerifier), "Update failed: address mismatch");
        console2.log("Verified: MultiProofVerifier.ziskVerifier() ==", updatedZisk);

        vm.stopBroadcast();
    }
}
