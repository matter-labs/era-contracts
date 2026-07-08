// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {EcosystemContract} from "./ContractIdentifiers.sol";
import {ICoreRegistry} from "./ICoreRegistry.sol";
import {RegistryUnknownKey} from "../../common/L1ContractErrors.sol";

/// @title Core (ecosystem-wide) registry logic base.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The FIXED, hand-written half of a generated core registry — see `CTMRegistryBase` for
///         the model: logic audited once here, generated per-upgrade code supplies data rows only.
abstract contract CoreRegistryBase is ICoreRegistry {
    /// @dev One ecosystem contract's proxy and per-version implementations. A zero
    ///      implementation means "not pinned for that version".
    struct EcosystemContractRow {
        EcosystemContract key;
        address proxy;
        address implOld;
        address implNew;
    }

    /// @dev One `address -> expected EXTCODEHASH` pin for `verifyAll`.
    struct CodehashPin {
        address target;
        bytes32 expectedCodehash;
    }

    /*//////////////////////////////////////////////////////////////
                        GENERATED DATA HOOKS
    //////////////////////////////////////////////////////////////*/

    function _oldProtocolVersion() internal pure virtual returns (uint256);

    function _newProtocolVersion() internal pure virtual returns (uint256);

    function _proxyAdmin() internal pure virtual returns (address);

    function _ctmRegistry(bool _isZKsyncOS) internal pure virtual returns (address);

    function _contractRows() internal pure virtual returns (EcosystemContractRow[] memory);

    function _codehashPins() internal pure virtual returns (CodehashPin[] memory);

    /*//////////////////////////////////////////////////////////////
                        ICoreRegistry (fixed logic)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICoreRegistry
    function oldProtocolVersion() external pure returns (uint256) {
        return _oldProtocolVersion();
    }

    /// @inheritdoc ICoreRegistry
    function newProtocolVersion() external pure returns (uint256) {
        return _newProtocolVersion();
    }

    /// @inheritdoc ICoreRegistry
    function proxyAddress(EcosystemContract _contract) external pure returns (address) {
        EcosystemContractRow[] memory rows = _contractRows();
        uint256 rowsLength = rows.length;
        for (uint256 i = 0; i < rowsLength; ++i) {
            if (rows[i].key == _contract) {
                return rows[i].proxy;
            }
        }
        revert RegistryUnknownKey();
    }

    /// @inheritdoc ICoreRegistry
    function implAddress(EcosystemContract _contract, uint256 _protocolVersion) external pure returns (address) {
        if (_protocolVersion != _oldProtocolVersion() && _protocolVersion != _newProtocolVersion()) {
            revert RegistryUnknownKey();
        }
        EcosystemContractRow[] memory rows = _contractRows();
        uint256 rowsLength = rows.length;
        for (uint256 i = 0; i < rowsLength; ++i) {
            if (rows[i].key == _contract) {
                return _protocolVersion == _oldProtocolVersion() ? rows[i].implOld : rows[i].implNew;
            }
        }
        // Known version, unpinned contract: no implementation pinned.
        return address(0);
    }

    /// @inheritdoc ICoreRegistry
    function ecosystemContractList() external pure returns (EcosystemContract[] memory list) {
        EcosystemContractRow[] memory rows = _contractRows();
        uint256 rowsLength = rows.length;
        list = new EcosystemContract[](rowsLength);
        for (uint256 i = 0; i < rowsLength; ++i) {
            list[i] = rows[i].key;
        }
    }

    /// @inheritdoc ICoreRegistry
    function proxyAdmin() external pure returns (address) {
        return _proxyAdmin();
    }

    /// @inheritdoc ICoreRegistry
    function ctmRegistry(bool _isZKsyncOS) external pure returns (address) {
        return _ctmRegistry(_isZKsyncOS);
    }

    /// @inheritdoc ICoreRegistry
    function verifyAll() external view returns (bool) {
        CodehashPin[] memory pins = _codehashPins();
        uint256 pinsLength = pins.length;
        for (uint256 i = 0; i < pinsLength; ++i) {
            if (pins[i].target.codehash != pins[i].expectedCodehash) {
                return false;
            }
        }
        return true;
    }
}
