// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {CTMRelease} from "contracts/upgrades/registry/CTMRelease.sol";
import {GenesisFacet} from "contracts/upgrades/registry/ICTMRelease.sol";
import {GenesisManifestLib} from "contracts/upgrades/registry/GenesisManifestLib.sol";
import {Facets} from "contracts/common/StateTransitionTypes.sol";
import {RegistryUnknownKey, RegistryAlreadyInitialized} from "contracts/common/L1ContractErrors.sol";

/// @notice Unit tests for `CTMRegistry` in its BOOTSTRAP (genesis) mode: a freshly deployed CTM
///         (L1 deploy scripts or the Gateway CTM deployer) points at one of these so
///         `DiamondInit` installs a new chain's facet set and reads the base system contract
///         hashes from it. Exercises the getter surface `RegistryFacetReader` / `DiamondInit`
///         read, the one-shot init guard, and the manifest-hash commitment.
contract CTMRegistryBootstrapTest is Test {
    CTMRelease internal release;

    uint256 internal constant VERSION = 42;
    bytes32 internal constant BOOTLOADER_HASH = bytes32(uint256(0xB001));
    bytes32 internal constant DEFAULT_ACCOUNT_HASH = bytes32(uint256(0xDEFA));
    bytes32 internal constant EVM_EMULATOR_HASH = bytes32(uint256(0xE7E7));

    Facets internal facets =
        Facets({
            adminFacet: address(0xA11),
            mailboxFacet: address(0x111A),
            executorFacet: address(0xE8E),
            gettersFacet: address(0x6E1),
            migratorFacet: address(0x111),
            committerFacet: address(0xC0111),
            diamondInit: address(0xD1)
        });

    function setUp() public {
        release = new CTMRelease();
    }

    function _genesisManifest() internal view returns (CTMRelease.ReleaseManifest memory) {
        return
            GenesisManifestLib.buildGenesisManifest(
                GenesisManifestLib.GenesisConfig({
                    isZKsyncOS: false,
                    protocolVersion: VERSION,
                    verifier: address(0xBEEF),
                    facets: facets,
                    bootloaderHash: BOOTLOADER_HASH,
                    defaultAccountHash: DEFAULT_ACCOUNT_HASH,
                    evmEmulatorHash: EVM_EMULATOR_HASH,
                    genesisUpgrade: address(0xABCD),
                    genesisBatchHash: bytes32(uint256(1)),
                    genesisBatchCommitment: bytes32(uint256(1)),
                    genesisIndexRepeatedStorageChanges: 1,
                    fixedForceDeploymentsData: bytes("")
                })
            );
    }

    // ---- Happy path ----

    function test_initializePinsGenesisManifest() public {
        CTMRelease.ReleaseManifest memory manifest = _genesisManifest();
        release.initialize(manifest);

        assertTrue(release.initialized(), "initialized");
        assertEq(release.manifestHash(), keccak256(abi.encode(manifest)), "manifest hash");
        assertEq(release.protocolVersion(), VERSION, "version");
        assertEq(release.verifier(), address(0xBEEF), "verifier");
        assertFalse(release.isZKsyncOS(), "vm flavour");

        GenesisFacet[] memory list = release.genesisFacets();
        assertEq(list.length, 6, "list length");
        assertEq(list[0].facet, facets.adminFacet, "admin addr");
        assertEq(list[1].facet, facets.gettersFacet, "getters addr");
        assertEq(list[5].facet, facets.committerFacet, "committer addr");

        // Canonical freezability: Mailbox/Executor/Committer freezable, the rest not.
        assertFalse(list[0].isFreezable, "admin freezable");
        assertTrue(list[2].isFreezable, "mailbox freezable");
        assertTrue(list[5].isFreezable, "committer freezable");

        // Selectors are always empty at genesis: DiamondInit self-describes from the facet's own
        // bytecode.
        assertEq(list[0].selectors.length, 0, "selectors empty");

        (bytes32 bootloaderHash, bytes32 defaultAccountHash, bytes32 evmEmulatorHash) = release
            .baseSystemContractHashes();
        assertEq(bootloaderHash, BOOTLOADER_HASH, "bootloader hash");
        assertEq(defaultAccountHash, DEFAULT_ACCOUNT_HASH, "default account hash");
        assertEq(evmEmulatorHash, EVM_EMULATOR_HASH, "evm emulator hash");

        // No codehash pins in a bootstrap manifest: trivially verified.
        release.validate();
        assertTrue(release.verifyAll(), "verifyAll");
    }

    // ---- Unhappy path ----

    function test_initializeRevertsOnSecondCall() public {
        release.initialize(_genesisManifest());

        vm.expectRevert(RegistryAlreadyInitialized.selector);
        release.initialize(_genesisManifest());
    }

    function test_initializeRevertsOnZeroNewVersion() public {
        CTMRelease.ReleaseManifest memory manifest = _genesisManifest();
        manifest.protocolVersion = 0;

        vm.expectRevert();
        release.initialize(manifest);
    }

    function test_validateRevertsBeforeInitialization() public {
        vm.expectRevert(RegistryUnknownKey.selector);
        release.validate();
        assertFalse(release.verifyAll(), "uninitialized release must not verify");
    }

    /// @dev ZKsync OS pins all-zero hashes; the registry must store and serve them as-is (the
    ///      zero-check lives in DiamondInit and is skipped for ZKsync OS chains).
    function test_zeroHashesAreServedForPinnedVersion() public {
        release.initialize(
            GenesisManifestLib.buildGenesisManifest(
                GenesisManifestLib.GenesisConfig({
                    isZKsyncOS: true,
                    protocolVersion: VERSION,
                    verifier: address(0xBEEF),
                    facets: facets,
                    bootloaderHash: 0,
                    defaultAccountHash: 0,
                    evmEmulatorHash: 0,
                    genesisUpgrade: address(0xABCD),
                    genesisBatchHash: bytes32(uint256(1)),
                    genesisBatchCommitment: bytes32(uint256(1)),
                    genesisIndexRepeatedStorageChanges: 1,
                    fixedForceDeploymentsData: bytes("")
                })
            )
        );

        (bytes32 bootloaderHash, bytes32 defaultAccountHash, bytes32 evmEmulatorHash) = release
            .baseSystemContractHashes();
        assertEq(bootloaderHash, bytes32(0), "bootloader hash");
        assertEq(defaultAccountHash, bytes32(0), "default account hash");
        assertEq(evmEmulatorHash, bytes32(0), "evm emulator hash");
        assertTrue(release.isZKsyncOS(), "vm flavour");
        assertEq(release.genesisFacets().length, 6, "facet list");
    }
}
