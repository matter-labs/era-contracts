// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "../../state-transition/libraries/Diamond.sol";
import {ZKChainBase} from "../../state-transition/chain-deps/facets/ZKChainBase.sol";
import {IChainTypeManager} from "../../state-transition/IChainTypeManager.sol";
import {HashMismatch, ProtocolIdMismatch, ProtocolIdNotGreater} from "../../common/L1ContractErrors.sol";

/// @title LegacyTestAdminFacet
/// @notice Test-only reimplementation of the pre-v34 cut-taking chain upgrade entrypoint: the
///         caller hands the diamond cut and the facet verifies it against the hash the chain's
///         CTM committed (`upgradeCutHash`).
/// @dev The anvil bootstrap-upgrade test installs this facet on chains built from CURRENT
///      sources so they can cross the bootstrap edge exactly like production pre-v34 chains do —
///      the current AdminFacet reads its cut from the CTM and cannot take one. Faithful to the
///      historical implementation except for the ServerNotifier timestamp gate, which only
///      applied to non-admin callers (the test calls as the chain admin).
contract LegacyTestAdminFacet is ZKChainBase {
    event ExecuteUpgrade(Diamond.DiamondCutData diamondCut);

    function upgradeChainFromVersion(
        address, // _chainAddress (unused, mirrors the historical signature)
        uint256 _oldProtocolVersion,
        Diamond.DiamondCutData calldata _diamondCut
    ) external onlyAdminOrChainTypeManager {
        bytes32 cutHashInput = keccak256(abi.encode(_diamondCut));
        bytes32 committedCutHash = IChainTypeManager(s.chainTypeManager).upgradeCutHash(_oldProtocolVersion);
        if (cutHashInput != committedCutHash) {
            revert HashMismatch(committedCutHash, cutHashInput);
        }
        if (s.protocolVersion != _oldProtocolVersion) {
            revert ProtocolIdMismatch(s.protocolVersion, _oldProtocolVersion);
        }
        Diamond.diamondCut(_diamondCut);
        emit ExecuteUpgrade(_diamondCut);
        if (s.protocolVersion <= _oldProtocolVersion) {
            revert ProtocolIdNotGreater();
        }
    }
}
