// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ZKsyncOSVerifierFflonk} from "contracts/state-transition/verifiers/ZKsyncOSVerifierFflonk.sol";
import {ZKsyncOSVerifierPlonk} from "contracts/state-transition/verifiers/ZKsyncOSVerifierPlonk.sol";
import {ZKsyncOSTestnetVerifier} from "contracts/state-transition/verifiers/ZKsyncOSTestnetVerifier.sol";
import {ZKsyncOSDualVerifier} from "contracts/state-transition/verifiers/ZKsyncOSDualVerifier.sol";
import {EraVerifierFflonk} from "contracts/state-transition/verifiers/EraVerifierFflonk.sol";
import {EraVerifierPlonk} from "contracts/state-transition/verifiers/EraVerifierPlonk.sol";
import {EraTestnetVerifier} from "contracts/state-transition/verifiers/EraTestnetVerifier.sol";
import {EraDualVerifier} from "contracts/state-transition/verifiers/EraDualVerifier.sol";

import {IVerifierV2} from "contracts/state-transition/chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {IEraDualVerifier} from "contracts/state-transition/chain-interfaces/IEraDualVerifier.sol";
import {IZKsyncOSDualVerifier} from "contracts/state-transition/chain-interfaces/IZKsyncOSDualVerifier.sol";

/// @notice Verifier deployment lifecycle logic for Era and ZKsyncOS.
///         This library is an internal implementation detail of EraZkosRouter.
///         External callers should use EraZkosRouter's public API instead.
library EraZkosVerifierLifecycle {
    // TODO: pass this value from zkstack_cli
    uint32 internal constant DEFAULT_ZKSYNC_OS_VERIFIER_VERSION = 6;

    // ======================== Creation code ========================

    /// @notice Return the creation bytecode for the fflonk verifier.
    function getVerifierFflonkCreationCode(bool _isZKsyncOS) internal pure returns (bytes memory) {
        return _isZKsyncOS ? type(ZKsyncOSVerifierFflonk).creationCode : type(EraVerifierFflonk).creationCode;
    }

    /// @notice Return the creation bytecode for the plonk verifier.
    function getVerifierPlonkCreationCode(bool _isZKsyncOS) internal pure returns (bytes memory) {
        return _isZKsyncOS ? type(ZKsyncOSVerifierPlonk).creationCode : type(EraVerifierPlonk).creationCode;
    }

    /// @notice Return the creation bytecode for the main (dual or testnet) verifier.
    function getVerifierCreationCode(bool _testnetVerifier, bool _isZKsyncOS) internal pure returns (bytes memory) {
        if (_testnetVerifier) {
            return
                _isZKsyncOS
                    ? type(ZKsyncOSTestnetVerifier).creationCode
                    : type(EraTestnetVerifier).creationCode;
        }
        return _isZKsyncOS ? type(ZKsyncOSDualVerifier).creationCode : type(EraDualVerifier).creationCode;
    }

    // ======================== Constructor args ========================

    /// @notice Encode constructor arguments for the main verifier.
    ///         ZKsyncOS verifiers require an extra `_owner` argument.
    function getVerifierCreationArgs(
        address _fflonk,
        address _plonk,
        address _owner,
        bool _isZKsyncOS
    ) internal pure returns (bytes memory) {
        if (_isZKsyncOS) {
            return abi.encode(_fflonk, _plonk, _owner);
        }
        return abi.encode(_fflonk, _plonk);
    }

    // ======================== Post-deploy initialisation ========================

    /// @notice Perform any post-deploy steps required for the verifier.
    ///         For ZKsyncOS: registers sub-verifiers at the default version and
    ///         transfers ownership. For Era: no-op.
    /// @dev Caller must handle vm.startBroadcast / vm.stopBroadcast around this call.
    function initializeVerifier(
        address _verifier,
        address _fflonk,
        address _plonk,
        address _owner,
        bool _isZKsyncOS
    ) internal {
        if (!_isZKsyncOS) {
            return;
        }

        ZKsyncOSDualVerifier(_verifier).addVerifier(
            DEFAULT_ZKSYNC_OS_VERIFIER_VERSION,
            IVerifierV2(_fflonk),
            IVerifier(_plonk)
        );
        ZKsyncOSDualVerifier(_verifier).transferOwnership(_owner);
    }

    // ======================== Ownership ========================

    /// @notice Transfer ownership of a ZKsyncOS dual verifier. No-op for Era verifiers
    ///         (which have no ownership concept).
    function transferVerifierOwnership(address _verifier, address _newOwner, bool _isZKsyncOS) internal {
        if (!_isZKsyncOS) {
            return;
        }
        ZKsyncOSDualVerifier(_verifier).transferOwnership(_newOwner);
    }

    // ======================== Sub-verifier introspection ========================

    /// @notice Retrieve sub-verifier addresses from a deployed dual verifier.
    ///         Era uses immutable getters; ZKsyncOS uses versioned mappings.
    function getSubVerifiers(
        address _verifier,
        bool _isZKsyncOS
    ) internal view returns (address fflonk, address plonk) {
        if (_verifier == address(0)) {
            return (address(0), address(0));
        }

        if (_isZKsyncOS) {
            IZKsyncOSDualVerifier verifier = IZKsyncOSDualVerifier(_verifier);
            fflonk = address(verifier.fflonkVerifiers(DEFAULT_ZKSYNC_OS_VERIFIER_VERSION));
            plonk = address(verifier.plonkVerifiers(DEFAULT_ZKSYNC_OS_VERIFIER_VERSION));
        } else {
            IEraDualVerifier verifier = IEraDualVerifier(_verifier);
            fflonk = address(verifier.FFLONK_VERIFIER());
            plonk = address(verifier.PLONK_VERIFIER());
        }
    }
}
