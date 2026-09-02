// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// It's required to disable lints to force the compiler to compile the contracts
// solhint-disable no-unused-import

import {Call} from "contracts/governance/Common.sol";
import {SafeCast} from "@openzeppelin/contracts-v4/utils/math/SafeCast.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IZKsyncOSVerifier} from "contracts/state-transition/chain-interfaces/IZKsyncOSVerifier.sol";

/// @notice Scripts that is responsible for preparing the chain to become a gateway
library UpgradeUtils {
    /// @dev First protocol version whose production verifier exports `IS_TESTNET_VERIFIER()`.
    uint32 internal constant FIRST_PROTOCOL_VERSION_WITH_VERIFIER_FLAG = 34;

    /// @notice Resolves whether the ecosystem runs a testnet verifier by asking the currently
    /// deployed verifier of the given CTM.
    /// @dev From v34 every ZKsync OS verifier exports the flag, so it is called directly and a
    /// wrong verifier address fails loudly. Pre-v34 only testnet verifiers export it — the
    /// production verifier reverts — so for those versions a revert maps to "production".
    /// Temporary shim: once every environment these scripts can meet is on v34+, the pre-v34
    /// branch can be deleted in favor of the direct call.
    function resolveTestnetVerifier(IChainTypeManager _ctm, address _verifier) internal view returns (bool) {
        (, uint32 minor, ) = SemVer.unpackSemVer(SafeCast.toUint96(_ctm.protocolVersion()));
        if (minor >= FIRST_PROTOCOL_VERSION_WITH_VERIFIER_FLAG) {
            return IZKsyncOSVerifier(_verifier).IS_TESTNET_VERIFIER();
        }
        (bool ok, bytes memory data) = _verifier.staticcall(abi.encodeCall(IZKsyncOSVerifier.IS_TESTNET_VERIFIER, ()));
        if (!ok) {
            return false;
        }
        require(data.length == 32, "unexpected IS_TESTNET_VERIFIER returndata");
        return abi.decode(data, (bool));
    }

    /// @notice Merge array of Call arrays into single Call array
    function mergeCallsArray(Call[][] memory a) public pure returns (Call[] memory result) {
        uint256 resultLength;

        for (uint256 i; i < a.length; i++) {
            resultLength += a[i].length;
        }

        result = new Call[](resultLength);

        uint256 counter;
        for (uint256 i; i < a.length; i++) {
            for (uint256 j; j < a[i].length; j++) {
                result[counter] = a[i][j];
                counter++;
            }
        }
    }
}
