// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Strings} from "@openzeppelin/contracts-v4/utils/Strings.sol";

import {StateTransitionContracts} from "contracts/common/StateTransitionTypes.sol";

import {Utils} from "../../utils/Utils.sol";

/// @title CTMDomainProxies
/// @author Matter Labs
/// @notice The CTM-domain `ProxyAdmin` rule the v35 bootstrap requires, shared by
///         `SplitCTMProxyAdmin` and the `CTMUpgrade_v35` prepare:
///         {docs/upgrade-operations.md#splitting-a-shared-ctm-domain-proxyadmin}.
library CTMDomainProxies {
    /// @notice What every refusal below points the operator at.
    string internal constant REMEDY = "; run SplitCTMProxyAdmin and execute its calls first";

    /// @notice The CTM domain's proxies with their names, zero entries left out, the CTM first.
    /// @param _proxies The domain's proxies (`AddressIntrospector.getCTMProxies`).
    /// @return proxies The non-zero proxies.
    /// @return names Their contract names, for messages.
    function list(
        StateTransitionContracts memory _proxies
    ) internal pure returns (address[] memory proxies, string[] memory names) {
        address[6] memory all = [
            _proxies.chainTypeManager,
            _proxies.validatorTimelock,
            _proxies.bytecodesSupplier,
            _proxies.permissionlessValidator,
            _proxies.serverNotifier,
            _proxies.interopFeeManager
        ];
        string[6] memory allNames = [
            "ChainTypeManager",
            "ValidatorTimelock",
            "BytecodesSupplier",
            "PermissionlessValidator",
            "ServerNotifier",
            "L1InteropFeeManager"
        ];
        uint256 count = 0;
        for (uint256 i = 0; i < all.length; ++i) {
            if (all[i] != address(0)) {
                ++count;
            }
        }
        proxies = new address[](count);
        names = new string[](count);
        uint256 next = 0;
        for (uint256 i = 0; i < all.length; ++i) {
            if (all[i] != address(0)) {
                proxies[next] = all[i];
                names[next] = allNames[i];
                ++next;
            }
        }
    }

    /// @notice Reverts unless the CTM domain is split off the ecosystem: `_ctmAdmin` is not
    ///         `_ecosystemAdmin` and every CTM-domain proxy sits behind `_ctmAdmin`, except a
    ///         ServerNotifier behind an admin of its own (the bootstrap's handover moves it).
    /// @param _proxies The domain's proxies (`AddressIntrospector.getCTMProxies`).
    /// @param _ctmAdmin The CTM-domain `ProxyAdmin` (the CTM proxy's).
    /// @param _ecosystemAdmin The ecosystem `ProxyAdmin` (the Bridgehub's).
    function requireSplit(
        StateTransitionContracts memory _proxies,
        address _ctmAdmin,
        address _ecosystemAdmin
    ) internal view {
        require(_ctmAdmin != _ecosystemAdmin, string.concat("CTM domain shares the ecosystem ProxyAdmin", REMEDY));
        (address[] memory proxies, string[] memory names) = list(_proxies);
        for (uint256 i = 0; i < proxies.length; ++i) {
            address admin = Utils.getProxyAdminAddress(proxies[i]);
            if (admin == _ctmAdmin) {
                continue;
            }
            if (admin == _ecosystemAdmin) {
                revert(string.concat(names[i], " is still behind the ecosystem ProxyAdmin", REMEDY));
            }
            string memory found = string.concat(names[i], " is behind ", Strings.toHexString(admin));
            require(
                proxies[i] == _proxies.serverNotifier,
                string.concat(found, ", not the CTM-domain ProxyAdmin ", Strings.toHexString(_ctmAdmin))
            );
        }
    }
}
