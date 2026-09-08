// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {CTMRegistry} from "contracts/upgrades/registry/objects/CTMRegistry.sol";
import {InventoryDerivationLib} from "contracts/upgrades/registry/libraries/InventoryDerivationLib.sol";
import {CTM_CONTRACT_COUNT, CTMContract} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";
import {
    CTMInventoryRow,
    CTMRegistryManifest,
    PinnedContract,
    ProxyUpgradeRow
} from "contracts/upgrades/registry/RegistryTypes.sol";
import {MockProxyUpgradeInitImpl} from "contracts/dev-contracts/test/MockProxyUpgradeInitImpl.sol";
import {
    InventoryAdminChanged,
    InventoryMemberAdded,
    InventoryMemberRemoved,
    InventoryProxyChanged,
    ProxyUpgradeRowMismatch,
    RegistryCodehashMismatch,
    RegistryInventoryLengthMismatch,
    RegistryInventoryRowMalformed,
    RegistryInventorySlotNotOwnedHere,
    ZeroAddress
} from "contracts/common/L1ContractErrors.sol";

/// @dev Exposes the derivation library, which is internal.
contract DerivationHarness {
    function derive(
        CTMInventoryRow[] memory _source,
        CTMInventoryRow[] memory _target,
        bool[] memory _callInitializeUpgrade
    ) external pure returns (ProxyUpgradeRow[] memory) {
        return InventoryDerivationLib.deriveProxyUpgrades(_source, _target, _callInitializeUpgrade);
    }
}

/// @notice The CTM domain's current-deployment inventory and the operations derived from a pair of
///         them. See the batch-2 specification in {docs/upgrade-script-retirement.md}: an upgrade
///         row describes an OPERATION, an inventory row describes STATE, and the operations are a
///         pure function of the source and target snapshots.
contract CTMInventoryTest is Test {
    ProxyAdmin internal domainAdmin;
    ProxyAdmin internal foreignAdmin;
    DerivationHarness internal harness;

    address internal ctm;
    address internal implOld;
    address internal implNew;
    TransparentUpgradeableProxy internal timelock;

    function setUp() public {
        domainAdmin = new ProxyAdmin();
        foreignAdmin = new ProxyAdmin();
        harness = new DerivationHarness();
        ctm = makeAddr("ctm");
        implOld = address(new MockProxyUpgradeInitImpl());
        implNew = address(new MockProxyUpgradeInitImpl());
        // Distinct code, so an implementation swap is observable and its pin is meaningful.
        vm.etch(implNew, bytes.concat(implNew.code, hex"00"));
        timelock = new TransparentUpgradeableProxy(implOld, address(domainAdmin), hex"");
    }

    // ─────────────────────────── the object ───────────────────────────

    function test_inventoryPinsTheDomainAndItsMembers() public {
        CTMRegistry registry = new CTMRegistry(_manifest(_rowsWithTimelock(implOld, domainAdmin)));

        assertEq(registry.ctm(), ctm, "the inventory names the domain it describes");
        assertEq(registry.members().length, CTM_CONTRACT_COUNT, "one slot per member");
        CTMInventoryRow memory row = registry.member(uint256(CTMContract.ValidatorTimelock));
        assertEq(row.proxy, address(timelock));
        assertEq(row.implementation.addr, implOld);
        // Checkable against live state rather than merely asserted.
        registry.validate(address(domainAdmin));
        assertTrue(registry.verifyAll(address(domainAdmin)));
    }

    /// @dev The whole point of an inventory: it can be WRONG about live state, and says so.
    function test_inventoryDetectsAnImplementationItNoLongerDescribes() public {
        CTMRegistry registry = new CTMRegistry(_manifest(_rowsWithTimelock(implOld, domainAdmin)));

        // An out-of-band recovery call re-points the proxy. This is exactly the emergency change
        // the model has to surface rather than absorb.
        domainAdmin.upgrade(ITransparentUpgradeableProxy(payable(address(timelock))), implNew);

        assertFalse(registry.verifyAll(address(domainAdmin)), "a stale inventory must not verify");
        vm.expectRevert(abi.encodeWithSelector(ProxyUpgradeRowMismatch.selector, address(timelock), implOld, implNew));
        registry.validate(address(domainAdmin));
    }

    function test_revertWhen_inventoryPinDrifts() public {
        CTMInventoryRow[] memory rows = _rowsWithTimelock(implOld, domainAdmin);
        rows[uint256(CTMContract.ValidatorTimelock)].implementation.codehash = keccak256("not the code");
        CTMRegistry registry = new CTMRegistry(_manifest(rows));

        vm.expectRevert(
            abi.encodeWithSelector(
                RegistryCodehashMismatch.selector,
                implOld,
                keccak256("not the code"),
                implOld.codehash
            )
        );
        registry.validate(address(domainAdmin));
    }

    /// @dev A member the RELEASE authoritatively describes may not be described here too: two
    ///      sources for one address are two sources that can disagree.
    function test_revertWhen_inventoryDescribesAReleaseMember() public {
        CTMInventoryRow[] memory rows = _emptyRows();
        rows[uint256(CTMContract.MailboxFacet)] = CTMInventoryRow({
            proxy: address(timelock),
            admin: ProxyAdmin(address(0)),
            implementation: PinnedContract({addr: implOld, codehash: implOld.codehash})
        });

        vm.expectRevert(
            abi.encodeWithSelector(RegistryInventorySlotNotOwnedHere.selector, uint256(CTMContract.MailboxFacet))
        );
        new CTMRegistry(_manifest(rows));
    }

    function test_revertWhen_inventoryRowIsHalfPresent() public {
        CTMInventoryRow[] memory rows = _emptyRows();
        rows[uint256(CTMContract.ValidatorTimelock)] = CTMInventoryRow({
            proxy: address(timelock),
            admin: ProxyAdmin(address(0)),
            implementation: PinnedContract({addr: address(0), codehash: bytes32(0)})
        });

        vm.expectRevert(
            abi.encodeWithSelector(RegistryInventoryRowMalformed.selector, uint256(CTMContract.ValidatorTimelock))
        );
        new CTMRegistry(_manifest(rows));
    }

    function test_revertWhen_inventoryHasNoCtmOrWrongLength() public {
        CTMRegistryManifest memory manifest = _manifest(_emptyRows());
        manifest.ctm = address(0);
        vm.expectRevert(ZeroAddress.selector);
        new CTMRegistry(manifest);

        manifest = _manifest(new CTMInventoryRow[](CTM_CONTRACT_COUNT - 1));
        vm.expectRevert(
            abi.encodeWithSelector(RegistryInventoryLengthMismatch.selector, CTM_CONTRACT_COUNT, CTM_CONTRACT_COUNT - 1)
        );
        new CTMRegistry(manifest);
    }

    // ─────────────────────── the derivation table ───────────────────────

    /// @dev The timelock-only shape: one member's implementation replaced, everything else
    ///      untouched, so exactly one operation comes out and its source check is the source
    ///      inventory's implementation rather than a restated one.
    function test_derivesOneOperationForOneChangedMember() public view {
        ProxyUpgradeRow[] memory rows = harness.derive(
            _rowsWithTimelock(implOld, domainAdmin),
            _rowsWithTimelock(implNew, domainAdmin),
            _noReinit()
        );

        uint256 operations = 0;
        for (uint256 i = 0; i < rows.length; ++i) {
            if (rows[i].implNew.addr != address(0)) {
                ++operations;
            }
        }
        assertEq(operations, 1, "one changed member, one operation");
        ProxyUpgradeRow memory row = rows[uint256(CTMContract.ValidatorTimelock)];
        assertEq(row.proxy, address(timelock));
        assertEq(row.expectedOldImpl, implOld, "the replay guard comes from the source inventory");
        assertEq(row.implNew.addr, implNew);
        assertEq(row.implNew.codehash, implNew.codehash);
        // Zero carries the convention forward: the member is under the domain's own admin, the
        // one the bound executor holds.
        assertEq(address(row.admin), address(0), "a domain-administered member names no admin");
        assertFalse(row.callInitializeUpgrade);
    }

    /// @dev An unchanged member produces NO operation: this is what makes "read the inventory,
    ///      replace one implementation" cost one row instead of the whole domain.
    function test_derivesNothingWhenNothingChanged() public view {
        ProxyUpgradeRow[] memory rows = harness.derive(
            _rowsWithTimelock(implOld, domainAdmin),
            _rowsWithTimelock(implOld, domainAdmin),
            _noReinit()
        );
        for (uint256 i = 0; i < rows.length; ++i) {
            assertEq(rows[i].implNew.addr, address(0), "an unchanged inventory derives no operation");
        }
    }

    /// @dev Reinitialization is the TRANSITION's instruction, carried per member.
    function test_reinitializationRidesTheTransitionNotTheInventory() public view {
        bool[] memory reinit = _noReinit();
        reinit[uint256(CTMContract.ValidatorTimelock)] = true;
        ProxyUpgradeRow[] memory rows = harness.derive(
            _rowsWithTimelock(implOld, domainAdmin),
            _rowsWithTimelock(implNew, domainAdmin),
            reinit
        );
        assertTrue(rows[uint256(CTMContract.ValidatorTimelock)].callInitializeUpgrade);
    }

    /// @dev A member administered elsewhere keeps its administrator on the derived row, which is
    ///      what lets stage 1 leave it and stage 2 still require it.
    function test_derivedRowKeepsAForeignAdministrator() public view {
        ProxyUpgradeRow[] memory rows = harness.derive(
            _rowsWithTimelock(implOld, foreignAdmin),
            _rowsWithTimelock(implNew, foreignAdmin),
            _noReinit()
        );
        assertEq(
            address(rows[uint256(CTMContract.ValidatorTimelock)].admin),
            address(foreignAdmin),
            "the derived row names the administrator the inventory recorded"
        );
    }

    function test_revertWhen_targetAddsAMember() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                InventoryMemberAdded.selector,
                uint256(CTMContract.ValidatorTimelock),
                address(timelock)
            )
        );
        harness.derive(_emptyRows(), _rowsWithTimelock(implOld, domainAdmin), _noReinit());
    }

    function test_revertWhen_targetRemovesAMember() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                InventoryMemberRemoved.selector,
                uint256(CTMContract.ValidatorTimelock),
                address(timelock)
            )
        );
        harness.derive(_rowsWithTimelock(implOld, domainAdmin), _emptyRows(), _noReinit());
    }

    function test_revertWhen_targetMovesAMemberToAnotherProxy() public {
        CTMInventoryRow[] memory target = _rowsWithTimelock(implOld, domainAdmin);
        address otherProxy = makeAddr("otherProxy");
        target[uint256(CTMContract.ValidatorTimelock)].proxy = otherProxy;

        vm.expectRevert(
            abi.encodeWithSelector(
                InventoryProxyChanged.selector,
                uint256(CTMContract.ValidatorTimelock),
                address(timelock),
                otherProxy
            )
        );
        harness.derive(_rowsWithTimelock(implOld, domainAdmin), target, _noReinit());
    }

    function test_revertWhen_targetMovesAMemberToAnotherAdministrator() public {
        // Source: the domain's own admin, recorded as zero. Target: a named foreign one.
        vm.expectRevert(
            abi.encodeWithSelector(
                InventoryAdminChanged.selector,
                uint256(CTMContract.ValidatorTimelock),
                address(0),
                address(foreignAdmin)
            )
        );
        harness.derive(_rowsWithTimelock(implOld, domainAdmin), _rowsWithTimelock(implOld, foreignAdmin), _noReinit());
    }

    // ─────────────────────────── fixtures ───────────────────────────

    function _manifest(CTMInventoryRow[] memory _rows) internal view returns (CTMRegistryManifest memory) {
        return CTMRegistryManifest({ctm: ctm, members: _rows});
    }

    function _emptyRows() internal pure returns (CTMInventoryRow[] memory) {
        return new CTMInventoryRow[](CTM_CONTRACT_COUNT);
    }

    function _rowsWithTimelock(address _impl, ProxyAdmin _admin) internal view returns (CTMInventoryRow[] memory rows) {
        rows = _emptyRows();
        rows[uint256(CTMContract.ValidatorTimelock)] = CTMInventoryRow({
            proxy: address(timelock),
            admin: _admin == domainAdmin ? ProxyAdmin(address(0)) : _admin,
            implementation: PinnedContract({addr: _impl, codehash: _impl.codehash})
        });
    }

    function _noReinit() internal pure returns (bool[] memory) {
        return new bool[](CTM_CONTRACT_COUNT);
    }
}
