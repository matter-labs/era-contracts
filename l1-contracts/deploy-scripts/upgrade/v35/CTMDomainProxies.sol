// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {StateTransitionContracts} from "contracts/common/StateTransitionTypes.sol";

import {Utils} from "../../utils/Utils.sol";

/// @title CTMDomainProxies
/// @author Matter Labs
/// @notice The one rule the v35 bootstrap needs of a CTM domain's `ProxyAdmin`, shared by
///         `SplitCTMProxyAdmin` (which establishes it) and `CTMUpgrade_v35` (which refuses to
///         prepare without it). The bootstrap hands the ecosystem `ProxyAdmin` to the core executor
///         and the CTM-domain one to the CTM executor, so the two must differ, and every CTM-domain
///         proxy must sit behind the second or no executor could upgrade it afterwards.
/// @dev The proxies come from `AddressIntrospector.getCTMProxies`, the list the prepares read.
library CTMDomainProxies {
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
    ///         `_ecosystemAdmin` and every CTM-domain proxy sits behind `_ctmAdmin`. The
    ///         ServerNotifier may still sit behind an admin of its own (not the ecosystem's): the
    ///         bootstrap's ChainAdmin handover moves it.
    /// @param _proxies The domain's proxies (`AddressIntrospector.getCTMProxies`).
    /// @param _ctmAdmin The CTM-domain `ProxyAdmin` (the CTM proxy's).
    /// @param _ecosystemAdmin The ecosystem `ProxyAdmin` (the Bridgehub's).
    function requireSplit(
        StateTransitionContracts memory _proxies,
        address _ctmAdmin,
        address _ecosystemAdmin
    ) internal view {
        require(
            _ctmAdmin != _ecosystemAdmin,
            "CTM domain shares the ecosystem ProxyAdmin; run SplitCTMProxyAdmin and execute its calls first"
        );
        (address[] memory proxies, string[] memory names) = list(_proxies);
        for (uint256 i = 0; i < proxies.length; ++i) {
            address admin = Utils.getProxyAdminAddress(proxies[i]);
            if (admin == _ctmAdmin) {
                continue;
            }
            if (admin == _ecosystemAdmin) {
                revert(
                    string.concat(
                        names[i],
                        " is still behind the ecosystem ProxyAdmin; run SplitCTMProxyAdmin and execute its calls first"
                    )
                );
            }
            // The split moves only what the ecosystem admin holds; any other admin is a third
            // party's, except the notifier's own, which the handover moves.
            require(
                proxies[i] == _proxies.serverNotifier,
                string.concat(names[i], " is behind a ProxyAdmin that is neither the CTM-domain nor the ecosystem one")
            );
        }
    }
}
