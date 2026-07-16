// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L2EcosystemContract, L1EcosystemContract, CodehashPin} from "contracts/upgrades/registry/ContractIdentifiers.sol";
import {CoreRegistry} from "contracts/upgrades/registry/CoreRegistry.sol";
import {CTMRelease} from "contracts/upgrades/registry/CTMRelease.sol";
import {CTMTransition} from "contracts/upgrades/registry/CTMTransition.sol";
import {ICTMTransition, L2Deployment} from "contracts/upgrades/registry/ICTMTransition.sol";
import {ICTMRelease, GenesisFacet} from "contracts/upgrades/registry/ICTMRelease.sol";
import {CTMUpgradeComposer} from "contracts/upgrades/registry/CTMUpgradeComposer.sol";
import {ReleaseFacetReader} from "contracts/upgrades/registry/ReleaseFacetReader.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {ProposedUpgrade, UpgradeFacetSwap} from "contracts/state-transition/libraries/ProposedUpgradeLib.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE} from "contracts/common/Config.sol";
import {L2_COMPLEX_UPGRADER_ADDR, L2_FORCE_DEPLOYER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {RegistryAlreadyInitialized, RegistryCodehashMismatch} from "contracts/common/L1ContractErrors.sol";

contract StorageRegistriesTest is Test {
    CoreRegistry internal coreRegistry;
    CTMRelease internal release;
    CTMTransition internal transition;

    uint256 internal constant OLD_VERSION = uint256(98) << 32;
    uint256 internal constant NEW_VERSION = uint256(99) << 32;

    function setUp() public {
        coreRegistry = new CoreRegistry();
        coreRegistry.initialize(_coreManifest());
        release = new CTMRelease();
        release.initialize(_releaseManifest());
        transition = new CTMTransition();
        transition.initialize(_transitionManifest());
    }

    function _coreManifest() internal pure returns (CoreRegistry.CoreRegistryManifest memory manifest) {
        CoreRegistry.EcosystemContractRow[] memory rows = new CoreRegistry.EcosystemContractRow[](2);
        rows[0] = CoreRegistry.EcosystemContractRow({
            key: L1EcosystemContract.L1Bridgehub,
            proxy: address(0xB001),
            implNew: address(0xB201)
        });
        rows[1] = CoreRegistry.EcosystemContractRow({
            key: L1EcosystemContract.L1MessageRoot,
            proxy: address(0xB003),
            implNew: address(0)
        });
        CodehashPin[] memory pins = new CodehashPin[](1);
        pins[0] = CodehashPin({target: address(0xB201), expectedCodehash: keccak256(hex"6001600155")});
        return
            CoreRegistry.CoreRegistryManifest({
                oldProtocolVersion: OLD_VERSION,
                newProtocolVersion: NEW_VERSION,
                proxyAdmin: address(0xA001),
                contractRows: rows,
                codehashPins: pins
            });
    }

    function _releaseManifest() internal pure returns (CTMRelease.ReleaseManifest memory manifest) {
        GenesisFacet[] memory facets = new GenesisFacet[](3);
        facets[0] = GenesisFacet({
            facet: address(0xF201),
            isFreezable: false,
            selectors: _selectors2(bytes4(uint32(2)), bytes4(uint32(3)))
        });
        facets[1] = GenesisFacet({
            facet: address(0xF102),
            isFreezable: false,
            selectors: _selectors2(bytes4(uint32(0x10)), bytes4(uint32(0x11)))
        });
        facets[2] = GenesisFacet({
            facet: address(0xF203),
            isFreezable: true,
            selectors: _selectors1(bytes4(uint32(0x20)))
        });
        return
            CTMRelease.ReleaseManifest({
                isZKsyncOS: true,
                protocolVersion: NEW_VERSION,
                verifier: address(0xE002),
                diamondInit: address(0xF204),
                genesisFacets: facets,
                bootloaderHash: bytes32(uint256(0xb00)),
                defaultAccountHash: bytes32(uint256(0xda0)),
                evmEmulatorHash: bytes32(0),
                fixedForceDeploymentsData: hex"f1f2",
                genesisUpgrade: address(0x10005),
                genesisBatchHash: bytes32(uint256(1)),
                genesisBatchCommitment: bytes32(uint256(1)),
                genesisIndexRepeatedStorageChanges: 54,
                codehashPins: new CodehashPin[](0)
            });
    }

    function _transitionManifest() internal view returns (CTMTransition.TransitionManifest memory manifest) {
        UpgradeFacetSwap[] memory swaps = new UpgradeFacetSwap[](3);
        swaps[0] = UpgradeFacetSwap({
            oldFacet: address(0xF101),
            newFacet: address(0xF201),
            isFreezable: false,
            oldSelectors: _selectors2(bytes4(uint32(1)), bytes4(uint32(2))),
            newSelectors: _selectors2(bytes4(uint32(2)), bytes4(uint32(3)))
        });
        swaps[1] = UpgradeFacetSwap({
            oldFacet: address(0xF103),
            newFacet: address(0),
            isFreezable: false,
            oldSelectors: _selectors1(bytes4(uint32(0x30))),
            newSelectors: new bytes4[](0)
        });
        swaps[2] = UpgradeFacetSwap({
            oldFacet: address(0),
            newFacet: address(0xF203),
            isFreezable: true,
            oldSelectors: new bytes4[](0),
            newSelectors: _selectors1(bytes4(uint32(0x20)))
        });

        L2Deployment[] memory deployments = new L2Deployment[](2);
        deployments[0] = _deployment(L2EcosystemContract.L2Bridgehub, address(0x10002), hex"aa01", 1);
        deployments[1] = _deployment(L2EcosystemContract.L2AssetRouter, address(0x10003), hex"aa02", 2);
        uint256[] memory factoryDeps = new uint256[](2);
        factoryDeps[0] = 1;
        factoryDeps[1] = 2;

        return
            CTMTransition.TransitionManifest({
                ctmProxy: address(0xD001),
                oldProtocolVersion: OLD_VERSION,
                newRelease: address(release),
                defaultUpgrade: address(0xF205),
                oldProtocolVersionDeadline: 1000,
                upgradeTimestamp: 1234567,
                facetTransitions: swaps,
                l2Deployments: deployments,
                l2UpgradeDelegateTo: address(0x10004),
                l2UpgradeDelegateCalldata: hex"beef",
                factoryDepHashes: factoryDeps,
                bootloaderHash: bytes32(uint256(0xb00)),
                defaultAccountHash: bytes32(uint256(0xda0)),
                evmEmulatorHash: bytes32(0),
                codehashPins: new CodehashPin[](0)
            });
    }

    function _deployment(
        L2EcosystemContract _key,
        address _newAddress,
        bytes memory _bytecodeInfo,
        uint256 _hash
    ) internal pure returns (L2Deployment memory) {
        return
            L2Deployment({
                key: _key,
                info: IComplexUpgrader.UniversalContractUpgradeInfo({
                    upgradeType: IComplexUpgrader.ContractUpgradeType.ZKsyncOSSystemProxyUpgrade,
                    deployedBytecodeInfo: _bytecodeInfo,
                    newAddress: _newAddress
                }),
                bytecodeHash: bytes32(_hash)
            });
    }

    function _selectors1(bytes4 _a) internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = _a;
    }

    function _selectors2(bytes4 _a, bytes4 _b) internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = _a;
        selectors[1] = _b;
    }

    function test_manifestsAreWriteOnceAndCommitted() public {
        assertEq(coreRegistry.manifestHash(), keccak256(abi.encode(_coreManifest())));
        assertEq(release.manifestHash(), keccak256(abi.encode(_releaseManifest())));
        assertEq(transition.manifestHash(), keccak256(abi.encode(_transitionManifest())));

        vm.expectRevert(RegistryAlreadyInitialized.selector);
        release.initialize(_releaseManifest());
        vm.expectRevert(RegistryAlreadyInitialized.selector);
        transition.initialize(_transitionManifest());
    }

    function test_releasePinsPostUpgradeGenesis() public view {
        assertEq(release.protocolVersion(), NEW_VERSION);
        assertEq(release.verifier(), address(0xE002));
        assertEq(release.diamondInit(), address(0xF204));
        assertEq(release.fixedForceDeploymentsData(), hex"f1f2");
        Diamond.FacetCut[] memory installations = ReleaseFacetReader.newChainInstallations(ICTMRelease(address(release)));
        assertEq(installations.length, 3);
        assertEq(installations[0].facet, address(0xF201));
        assertEq(installations[2].facet, address(0xF203));
        assertTrue(installations[2].isFreezable);
    }

    function test_transitionPinsMovementOnly() public view {
        assertEq(transition.oldProtocolVersion(), OLD_VERSION);
        assertEq(transition.newRelease(), address(release));
        assertEq(transition.defaultUpgrade(), address(0xF205));
        assertEq(transition.oldProtocolVersionDeadline(), 1000);
        UpgradeFacetSwap[] memory swaps = transition.facetTransitions();
        assertEq(swaps.length, 3);
        assertEq(swaps[0].oldFacet, address(0xF101));
        assertEq(swaps[0].newFacet, address(0xF201));
        assertEq(swaps[1].newFacet, address(0));
        assertEq(swaps[2].oldFacet, address(0));
    }

    function test_composerReadsReleaseAndTransitionWithoutVersionLookups() public view {
        L2CanonicalTransaction memory transaction = CTMUpgradeComposer.buildL2UpgradeTx(
            ICTMTransition(address(transition))
        );
        assertEq(transaction.txType, ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE);
        assertEq(transaction.from, uint256(uint160(L2_FORCE_DEPLOYER_ADDR)));
        assertEq(transaction.to, uint256(uint160(L2_COMPLEX_UPGRADER_ADDR)));
        assertEq(transaction.nonce, 99);
        (, uint32 minor, ) = SemVer.unpackSemVer(uint96(NEW_VERSION));
        assertEq(transaction.nonce, minor);
        assertEq(transaction.factoryDeps.length, 2);

        ProposedUpgrade memory proposedUpgrade = CTMUpgradeComposer.buildProposedUpgrade(
            ICTMTransition(address(transition))
        );
        assertEq(proposedUpgrade.newProtocolVersion, NEW_VERSION);
        assertEq(proposedUpgrade.upgradeTimestamp, 1234567);
        assertEq(proposedUpgrade.bootloaderHash, bytes32(uint256(0xb00)));
    }

    function test_validateRejectsCodehashDrift() public {
        assertFalse(coreRegistry.verifyAll());
        vm.expectRevert(RegistryCodehashMismatch.selector);
        coreRegistry.validate();

        vm.etch(address(0xB201), hex"6001600155");
        coreRegistry.validate();
        assertTrue(coreRegistry.verifyAll());
        release.validate();
        transition.validate();
    }
}
