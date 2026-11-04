// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L2DACommitmentScheme} from "contracts/common/Config.sol";
import {
    AddressIntrospector,
    ERA_L2_DA_SCHEME_MINOR,
    ZKSYNC_OS_L2_DA_SCHEME_MINOR
} from "deploy-scripts/utils/AddressIntrospector.sol";

/// Covers how `getDAValidatorPair()`'s second return value is interpreted. `l2DAValidator`
/// (an address) was replaced by the packed `l2DACommitmentScheme` enum, and the per-chain
/// migration lands at a different release for each CTM flavour: ZKsync-OS chains at v30
/// (`L1ZKsyncOSV30Upgrade`), Era chains at v31 (`SettlementLayerV31UpgradeBase`). The values
/// below are the ones the live chains actually return, read off mainnet and Sepolia.
contract L2DACommitmentSchemeTest is Test {
    /// Mainnet Era chain 324 at v0.30.1: not yet migrated, so the getter still answers with
    /// its real `l2DAValidator`. Decoding that as the enum is what used to revert the whole
    /// mainnet Era prepare, so it has to come back as `NONE` instead.
    function test_unmigratedEraChainReportsNoScheme() public pure {
        uint256 l2DAValidator = uint256(uint160(0xfa96A3Da88f201433911bEFf3Ecc434CB1222731));
        assertEq(
            uint256(AddressIntrospector.l2DACommitmentSchemeFromRaw(30, l2DAValidator)),
            uint256(L2DACommitmentScheme.NONE)
        );
    }

    /// Sepolia ZKsync-OS chains 17986 and 29538, both at v0.30.0: migrated by their v30
    /// upgrade, so at the same version as the Era chain above they report a real scheme.
    function test_migratedZKsyncOsChainAtTheSameVersionReportsItsScheme() public pure {
        assertEq(
            uint256(AddressIntrospector.l2DACommitmentSchemeFromRaw(ZKSYNC_OS_L2_DA_SCHEME_MINOR, 1)),
            uint256(L2DACommitmentScheme.EMPTY_NO_DA)
        );
    }

    /// Sepolia Era chain 301 at v0.31.0: past its own migration, so the value is the scheme.
    function test_migratedEraChainReportsItsScheme() public pure {
        assertEq(
            uint256(AddressIntrospector.l2DACommitmentSchemeFromRaw(ERA_L2_DA_SCHEME_MINOR, 3)),
            uint256(L2DACommitmentScheme.BLOBS_AND_PUBDATA_KECCAK256)
        );
    }

    function test_everyDeclaredSchemeSurvivesTheRoundTrip() public pure {
        for (uint256 scheme = 0; scheme <= uint256(type(L2DACommitmentScheme).max); ++scheme) {
            assertEq(uint256(AddressIntrospector.l2DACommitmentSchemeFromRaw(ERA_L2_DA_SCHEME_MINOR, scheme)), scheme);
        }
    }

    /// From v31 on there is no ambiguity left to resolve, so an out-of-range value means the
    /// chain's storage is corrupt and must not be silently reported as `NONE`.
    function test_revertWhen_migratedChainReportsAnUnknownScheme() public {
        uint256 outOfRange = uint256(type(L2DACommitmentScheme).max) + 1;
        vm.expectRevert();
        AddressIntrospector.l2DACommitmentSchemeFromRaw(ERA_L2_DA_SCHEME_MINOR, outOfRange);
    }

    /// The v30 disambiguation is by magnitude, so the boundary itself must land on the enum
    /// side and the value just past it on the address side.
    function test_v30BoundaryBetweenSchemeAndAddress() public pure {
        uint256 maxScheme = uint256(type(L2DACommitmentScheme).max);
        assertEq(
            uint256(AddressIntrospector.l2DACommitmentSchemeFromRaw(ZKSYNC_OS_L2_DA_SCHEME_MINOR, maxScheme)),
            maxScheme
        );
        assertEq(
            uint256(AddressIntrospector.l2DACommitmentSchemeFromRaw(ZKSYNC_OS_L2_DA_SCHEME_MINOR, maxScheme + 1)),
            uint256(L2DACommitmentScheme.NONE)
        );
    }
}
