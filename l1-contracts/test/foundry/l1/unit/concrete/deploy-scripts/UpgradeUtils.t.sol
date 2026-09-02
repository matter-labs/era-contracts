// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {UpgradeUtils} from "deploy-scripts/upgrade/default-upgrade/UpgradeUtils.sol";
import {FIRST_PROTOCOL_VERSION_WITH_VERIFIER_FLAG} from "deploy-scripts/utils/Types.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {ZKsyncOSVerifier} from "contracts/state-transition/verifiers/ZKsyncOSVerifier.sol";
import {ZKsyncOSTestnetVerifier} from "contracts/state-transition/verifiers/ZKsyncOSTestnetVerifier.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";

/// @notice Stands in for the CTM: the resolver consults only `protocolVersion()` and
/// `protocolVersionVerifier()`.
contract MockCTMVersion {
    uint256 public protocolVersion;
    address internal verifier;

    constructor(uint256 _protocolVersion, address _verifier) {
        protocolVersion = _protocolVersion;
        verifier = _verifier;
    }

    function protocolVersionVerifier(uint256) external view returns (address) {
        return verifier;
    }
}

/// @notice Mimics a pre-v34 testnet verifier, which exported the flag as a public constant.
contract LegacyTestnetVerifierMock {
    // solhint-disable-next-line func-name-mixedcase
    bool public constant IS_TESTNET_VERIFIER = true;
}

/// @notice Mimics a pre-v34 production verifier: no testnet-flag selector, so the probe reverts.
contract LegacyProductionVerifierMock {}

/// @notice Returns malformed (1-byte) returndata for any call.
contract WeirdReturndataVerifierMock {
    fallback() external {
        assembly {
            mstore8(0, 1)
            return(0, 1)
        }
    }
}

/// @notice External wrapper so reverts inside the internal library function are assertable.
contract ResolveTestnetVerifierHarness {
    function resolve(IChainTypeManager _ctm) external view returns (bool) {
        return UpgradeUtils.resolveTestnetVerifier(_ctm);
    }
}

/// @notice Unit tests for UpgradeUtils.resolveTestnetVerifier.
contract UpgradeUtilsResolveTestnetVerifierTest is Test {
    ResolveTestnetVerifierHarness internal harness;
    address internal productionVerifier;
    address internal testnetVerifier;

    function setUp() public {
        harness = new ResolveTestnetVerifierHarness();
        productionVerifier = address(new ZKsyncOSVerifier(IVerifier(address(0))));
        testnetVerifier = address(new ZKsyncOSTestnetVerifier(IVerifier(address(0))));
    }

    function _ctmWith(uint32 _minor, address _verifier) internal returns (IChainTypeManager) {
        return IChainTypeManager(address(new MockCTMVersion(uint256(SemVer.packSemVer(0, _minor, 0)), _verifier)));
    }

    function _flagVersionCTM(address _verifier) internal returns (IChainTypeManager) {
        return _ctmWith(FIRST_PROTOCOL_VERSION_WITH_VERIFIER_FLAG, _verifier);
    }

    function _preFlagVersionCTM(address _verifier) internal returns (IChainTypeManager) {
        return _ctmWith(FIRST_PROTOCOL_VERSION_WITH_VERIFIER_FLAG - 1, _verifier);
    }

    function test_flagVersionProductionVerifier_resolvesFalse() public {
        assertFalse(harness.resolve(_flagVersionCTM(productionVerifier)));
    }

    function test_flagVersionTestnetVerifier_resolvesTrue() public {
        assertTrue(harness.resolve(_flagVersionCTM(testnetVerifier)));
    }

    function test_preFlagVersionLegacyTestnetVerifier_resolvesTrue() public {
        assertTrue(harness.resolve(_preFlagVersionCTM(address(new LegacyTestnetVerifierMock()))));
    }

    function test_preFlagVersionLegacyProductionVerifier_resolvesFalse() public {
        assertFalse(harness.resolve(_preFlagVersionCTM(address(new LegacyProductionVerifierMock()))));
    }

    function test_preFlagVersionCurrentTestnetVerifier_resolvesTrue() public {
        // A newer verifier can serve an older protocol version (staged upgrades, local test
        // environments): the current name answers before the legacy one is tried.
        assertTrue(harness.resolve(_preFlagVersionCTM(testnetVerifier)));
    }

    function test_preFlagVersionCurrentProductionVerifier_resolvesFalse() public {
        assertFalse(harness.resolve(_preFlagVersionCTM(productionVerifier)));
    }

    function test_preFlagVersionRevertsOnMalformedReturndata() public {
        IChainTypeManager ctm = _preFlagVersionCTM(address(new WeirdReturndataVerifierMock()));
        vm.expectRevert(bytes("unexpected testnet-verifier flag returndata"));
        harness.resolve(ctm);
    }

    function test_preFlagVersionRevertsOnCodelessVerifier() public {
        // A misconfigured CTM answer must fail loudly instead of resolving to "production".
        IChainTypeManager ctm = _preFlagVersionCTM(makeAddr("codeless verifier"));
        vm.expectRevert(bytes("verifier has no code"));
        harness.resolve(ctm);
    }

    function test_flagVersionRevertsOnCodelessVerifier() public {
        IChainTypeManager ctm = _flagVersionCTM(makeAddr("codeless verifier"));
        vm.expectRevert();
        harness.resolve(ctm);
    }

    function test_revertsWhenCTMHasNoVerifierForCurrentVersion() public {
        IChainTypeManager ctm = _flagVersionCTM(address(0));
        vm.expectRevert(bytes("verifier not set for the current protocol version"));
        harness.resolve(ctm);
    }
}
