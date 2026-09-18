// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {SYSTEM_UPGRADE_L2_TX_TYPE, ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE} from "contracts/common/Config.sol";
import {SafeCast} from "@openzeppelin/contracts-v4/utils/math/SafeCast.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {ProposedUpgradeLib} from "contracts/state-transition/libraries/ProposedUpgradeLib.sol";
import {VerifierParams} from "contracts/state-transition/chain-interfaces/IVerifier.sol";

library UpgradeHelperLib {
    function getEmptyVerifierParams() internal pure returns (VerifierParams memory) {
        return
            VerifierParams({
                recursionNodeLevelVkHash: bytes32(0),
                recursionLeafLevelVkHash: bytes32(0),
                recursionCircuitsSetVksHash: bytes32(0)
            });
    }

    function getProtocolUpgradeNonce(uint256 _protocolVersion) internal pure returns (uint256) {
        return (_protocolVersion >> 32);
    }

    function isPatchUpgrade(uint256 _protocolVersion) internal pure returns (bool) {
        (, , uint32 _patch) = SemVer.unpackSemVer(SafeCast.toUint96(_protocolVersion));
        return _patch != 0;
    }

    function getOldProtocolDeadline() internal pure returns (uint256) {
        return type(uint256).max;
    }

    function emptyUpgradeTx() internal pure returns (L2CanonicalTransaction memory) {
        return ProposedUpgradeLib.emptyL2CanonicalTransaction();
    }

    function getUpgradeTxType(bool _isZKsyncOS) internal pure returns (uint256) {
        return _isZKsyncOS ? ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE : SYSTEM_UPGRADE_L2_TX_TYPE;
    }
}
