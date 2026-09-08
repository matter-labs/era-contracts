// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ICTMRegistry} from "./ICTMRegistry.sol";
import {CodehashPinLib} from "../libraries/CodehashPinLib.sol";
import {CTM_CONTRACT_COUNT, CTMContract} from "../libraries/ContractIdentifiers.sol";
import {CTMInventoryRow, CTMRegistryManifest} from "../RegistryTypes.sol";
import {
    ProxyUpgradeRowMismatch,
    RegistryInventoryLengthMismatch,
    RegistryInventoryRowMalformed,
    RegistryInventorySlotNotOwnedHere,
    ZeroAddress
} from "../../../common/L1ContractErrors.sol";

/// @title CTMRegistry
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Storage-backed, write-once description of a CTM domain's CURRENT deployment — the
///         address book an upgrade departs from. See {ICTMRegistry} for why this is a separate
///         object from the upgrade rows, and the inventory section of
///         {docs/upgrade-script-retirement.md} for the model.
/// @dev Same discipline as {CTMRelease} and {CoreRegistry}: the whole manifest arrives in the
///      constructor, no state-mutating function exists, and `manifestHash` is the hash of the
///      stored encoding rather than a second copy that could disagree.
contract CTMRegistry is ICTMRegistry {
    /// @dev THE manifest, stored as its own ABI encoding (see {CTMRelease} for why).
    bytes internal encodedManifest;

    constructor(CTMRegistryManifest memory _manifest) {
        if (_manifest.ctm == address(0)) {
            revert ZeroAddress();
        }
        if (_manifest.members.length != CTM_CONTRACT_COUNT) {
            revert RegistryInventoryLengthMismatch(CTM_CONTRACT_COUNT, _manifest.members.length);
        }
        for (uint256 i = 0; i < CTM_CONTRACT_COUNT; ++i) {
            CTMInventoryRow memory row = _manifest.members[i];
            bool absent = row.proxy == address(0) &&
                address(row.admin) == address(0) &&
                row.implementation.addr == address(0) &&
                row.implementation.codehash == bytes32(0);
            if (absent) {
                continue;
            }
            // A present member needs both halves: an address with no pin cannot be checked, and a
            // pin with no address checks nothing.
            if (row.proxy == address(0) || row.implementation.addr == address(0)) {
                revert RegistryInventoryRowMalformed(i);
            }
            // The release owns what a chain RUNS. Describing one of its members here would make
            // the same address answerable from two objects.
            if (!_isDomainMember(CTMContract(i))) {
                revert RegistryInventorySlotNotOwnedHere(i);
            }
        }
        encodedManifest = abi.encode(_manifest);
    }

    /// @inheritdoc ICTMRegistry
    function manifestHash() external view returns (bytes32) {
        return keccak256(encodedManifest);
    }

    /// @notice The whole manifest, exactly as it was pinned.
    function getManifest() public view returns (CTMRegistryManifest memory) {
        return abi.decode(encodedManifest, (CTMRegistryManifest));
    }

    /// @inheritdoc ICTMRegistry
    function ctm() external view returns (address) {
        return getManifest().ctm;
    }

    /// @inheritdoc ICTMRegistry
    function members() external view returns (CTMInventoryRow[] memory) {
        return getManifest().members;
    }

    /// @inheritdoc ICTMRegistry
    function member(uint256 _member) external view returns (CTMInventoryRow memory) {
        return getManifest().members[_member];
    }

    /// @inheritdoc ICTMRegistry
    function validate(address _domainAdmin) public view {
        CTMInventoryRow[] memory rows = getManifest().members;
        for (uint256 i = 0; i < CTM_CONTRACT_COUNT; ++i) {
            if (rows[i].proxy == address(0)) {
                continue;
            }
            ProxyAdmin admin = address(rows[i].admin) == address(0) ? ProxyAdmin(_domainAdmin) : rows[i].admin;
            address liveImpl = admin.getProxyImplementation(ITransparentUpgradeableProxy(rows[i].proxy));
            if (liveImpl != rows[i].implementation.addr) {
                revert ProxyUpgradeRowMismatch(rows[i].proxy, rows[i].implementation.addr, liveImpl);
            }
            CodehashPinLib.requirePin(rows[i].implementation);
        }
    }

    /// @inheritdoc ICTMRegistry
    /// @dev Reverting and predicate forms of one check, so a monitor can ask without a try/catch
    ///      and an execution path can insist.
    function verifyAll(address _domainAdmin) external view returns (bool) {
        CTMInventoryRow[] memory rows = getManifest().members;
        for (uint256 i = 0; i < CTM_CONTRACT_COUNT; ++i) {
            if (rows[i].proxy == address(0)) {
                continue;
            }
            ProxyAdmin admin = address(rows[i].admin) == address(0) ? ProxyAdmin(_domainAdmin) : rows[i].admin;
            if (
                admin.getProxyImplementation(ITransparentUpgradeableProxy(rows[i].proxy)) != rows[i].implementation.addr
            ) {
                return false;
            }
            if (!CodehashPinLib.pinHolds(rows[i].implementation)) {
                return false;
            }
        }
        return true;
    }

    /// @dev The members a CTM domain actually deploys and administers: the proxies under its own
    ///      `ProxyAdmin`, plus the `ServerNotifier` under its ChainAdmin-owned one. Everything
    ///      else in the enum is either the release's (facets, `DiamondInit`, verifiers, the
    ///      genesis upgrade), a per-upgrade deployment (the upgrade engine), or a Gateway-side
    ///      deployer — none of which this object describes.
    function _isDomainMember(CTMContract _member) private pure returns (bool) {
        return
            _member == CTMContract.ChainTypeManager ||
            _member == CTMContract.ValidatorTimelock ||
            _member == CTMContract.BytecodesSupplier ||
            _member == CTMContract.PermissionlessValidator ||
            _member == CTMContract.ServerNotifier;
    }
}
