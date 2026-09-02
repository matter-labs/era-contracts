// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {UpgradeUtils} from "deploy-scripts/upgrade/default-upgrade/UpgradeUtils.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {ZKsyncOSVerifier} from "contracts/state-transition/verifiers/ZKsyncOSVerifier.sol";
import {ZKsyncOSTestnetVerifier} from "contracts/state-transition/verifiers/ZKsyncOSTestnetVerifier.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";

/// @notice Stands in for the CTM: only `protocolVersion()` is consulted by the resolver.
contract MockCTMVersion {
    uint256 public protocolVersion;

    constructor(uint256 _protocolVersion) {
        protocolVersion = _protocolVersion;
    }
}

/// @notice Mimics a pre-v34 production verifier: no `IS_TESTNET_VERIFIER()` selector, so the
/// probe call reverts.
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
    function resolve(IChainTypeManager _ctm, address _verifier) external view returns (bool) {
        return UpgradeUtils.resolveTestnetVerifier(_ctm, _verifier);
    }
}

/// @notice Unit tests for UpgradeUtils.resolveTestnetVerifier.
contract UpgradeUtilsResolveTestnetVerifierTest is Test {
    ResolveTestnetVerifierHarness internal harness;
    IChainTypeManager internal ctmV33;
    IChainTypeManager internal ctmV34;
    address internal productionVerifier;
    address internal testnetVerifier;

    function setUp() public {
        harness = new ResolveTestnetVerifierHarness();
        ctmV33 = IChainTypeManager(address(new MockCTMVersion(uint256(SemVer.packSemVer(0, 33, 0)))));
        ctmV34 = IChainTypeManager(address(new MockCTMVersion(uint256(SemVer.packSemVer(0, 34, 0)))));
        productionVerifier = address(new ZKsyncOSVerifier(IVerifier(address(0))));
        testnetVerifier = address(new ZKsyncOSTestnetVerifier(IVerifier(address(0))));
    }

    function test_v34ProductionVerifier_resolvesFalse() public view {
        assertFalse(harness.resolve(ctmV34, productionVerifier));
    }

    function test_v34TestnetVerifier_resolvesTrue() public view {
        assertTrue(harness.resolve(ctmV34, testnetVerifier));
    }

    function test_preV34TestnetVerifier_resolvesTrue() public view {
        assertTrue(harness.resolve(ctmV33, testnetVerifier));
    }

    function test_preV34LegacyProductionVerifier_resolvesFalse() public {
        address legacyProduction = address(new LegacyProductionVerifierMock());
        assertFalse(harness.resolve(ctmV33, legacyProduction));
    }

    function test_preV34RevertsOnMalformedReturndata() public {
        address weird = address(new WeirdReturndataVerifierMock());
        vm.expectRevert(bytes("unexpected IS_TESTNET_VERIFIER returndata"));
        harness.resolve(ctmV33, weird);
    }

    function test_preV34RevertsOnCodelessVerifier() public {
        // A staticcall to an address without code succeeds with empty returndata: a misconfigured
        // verifier address must fail loudly instead of resolving to "production".
        vm.expectRevert(bytes("unexpected IS_TESTNET_VERIFIER returndata"));
        harness.resolve(ctmV33, makeAddr("codeless verifier"));
    }

    function test_v34RevertsOnCodelessVerifier() public {
        vm.expectRevert();
        harness.resolve(ctmV34, makeAddr("codeless verifier"));
    }
}
