// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// It's required to disable lints to force the compiler to compile the contracts
// solhint-disable no-unused-import

import {Call} from "contracts/governance/Common.sol";
import {SafeCast} from "@openzeppelin/contracts-v4/utils/math/SafeCast.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IZKsyncOSVerifier} from "contracts/state-transition/chain-interfaces/IZKsyncOSVerifier.sol";
import {FIRST_PROTOCOL_VERSION_WITH_VERIFIER_FLAG} from "../../utils/Types.sol";

/// @dev Getter that pre-v34 testnet verifiers exported as a public constant; pre-v34 production
/// verifiers don't have it.
interface ILegacyTestnetVerifier {
    // solhint-disable-next-line func-name-mixedcase
    function IS_TESTNET_VERIFIER() external view returns (bool);
}

/// @notice Scripts that is responsible for preparing the chain to become a gateway
library UpgradeUtils {
    /// @notice Resolves whether the ecosystem runs a testnet verifier by asking the verifier the
    /// given CTM reports for its current protocol version.
    /// @dev The verifier address is read from the CTM itself so a stale or mistyped address in the
    /// script config cannot skew the answer. From v34 every ZKsync OS verifier exports the flag,
    /// so it is called directly and a wrong deployment fails loudly. Pre-v34 the deployed verifier
    /// may answer under the current name (a newer verifier serving an older version) or the legacy
    /// constant name; only a verifier answering neither is a pre-v34 production verifier.
    /// Temporary shim: once every environment these scripts can meet is on v34+, the pre-v34
    /// branches can be deleted in favor of the direct call.
    function resolveTestnetVerifier(IChainTypeManager _ctm) internal view returns (bool) {
        uint256 packedProtocolVersion = _ctm.protocolVersion();
        address verifier = _ctm.protocolVersionVerifier(packedProtocolVersion);
        require(verifier != address(0), "verifier not set for the current protocol version");
        (, uint32 minor, ) = SemVer.unpackSemVer(SafeCast.toUint96(packedProtocolVersion));
        if (minor >= FIRST_PROTOCOL_VERSION_WITH_VERIFIER_FLAG) {
            return IZKsyncOSVerifier(verifier).isTestnetVerifier();
        }
        require(verifier.code.length != 0, "verifier has no code");
        (bool ok, bytes memory data) = verifier.staticcall(abi.encodeCall(IZKsyncOSVerifier.isTestnetVerifier, ()));
        if (!ok) {
            (ok, data) = verifier.staticcall(abi.encodeCall(ILegacyTestnetVerifier.IS_TESTNET_VERIFIER, ()));
        }
        if (!ok) {
            return false;
        }
        require(data.length == 32, "unexpected testnet-verifier flag returndata");
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
