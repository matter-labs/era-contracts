// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable gas-custom-errors

import {Vm} from "forge-std/Vm.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";

/// @notice Checks the upgrade prepares run against live state before they build an upgrade that would be unsafe
///         to apply there.
library UpgradeSafetyChecks {
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    // solhint-disable-next-line const-name-snakecase
    Vm internal constant vm = Vm(VM_ADDRESS);

    /// @notice The oldest chain version (packed 0.33.0) the L1 code of this line can be swapped in under: it keeps
    ///         no state or message format from before v0.33.0.
    ///         See {docs/registry-driven-upgrades.md#preconditions-checked-against-live-state}.
    uint256 internal constant MIN_CHAIN_PROTOCOL_VERSION_FOR_CORE_UPGRADE = 33 << 32;

    /// @notice The environment variable that lets an operator run a core upgrade over chains the check refuses,
    ///         once their old-format withdrawals and failed deposits are settled.
    string internal constant ALLOW_LEGACY_CHAINS_ENV = "UPGRADE_ALLOW_CORE_UPGRADE_OVER_LEGACY_CHAINS";

    /// @notice Refuses a plain implementation swap of a validator timelock proxy below initializer version 2. Such a
    ///         proxy still runs as a plain `ValidatorTimelock`, and moving it to `MultisigCommitter` needs
    ///         `reinitializeV2` in the same transaction as the swap, which a plain swap does not send.
    /// @param _proxy The validator timelock proxy.
    function requireValidatorTimelockAtVersion2(address _proxy) internal view {
        // `Initializable._initialized` is the lowest byte of slot 0 in the timelock's storage layout.
        uint8 initializedVersion = uint8(uint256(vm.load(_proxy, bytes32(0))));
        require(
            initializedVersion >= 2,
            string.concat(
                "validator timelock ",
                vm.toString(_proxy),
                " is below initializer version 2: move it with upgradeAndCall(MultisigCommitter, reinitializeV2) first"
            )
        );
    }

    /// @notice Refuses a core upgrade of a bridgehub that hosts a chain on an EraVM chain type manager, or a chain
    ///         below {MIN_CHAIN_PROTOCOL_VERSION_FOR_CORE_UPGRADE}, unless {ALLOW_LEGACY_CHAINS_ENV} is set.
    /// @param _bridgehub The bridgehub whose ecosystem the core upgrade targets.
    function requireCoreUpgradeTargetHasNoLegacyChains(address _bridgehub) internal view {
        if (vm.envOr(ALLOW_LEGACY_CHAINS_ENV, false)) {
            return;
        }
        IBridgehubBase bridgehub = IBridgehubBase(_bridgehub);
        uint256[] memory chainIds = bridgehub.getAllZKChainChainIDs();
        uint256 length = chainIds.length;
        for (uint256 i = 0; i < length; ++i) {
            uint256 chainId = chainIds[i];
            require(
                IChainTypeManager(bridgehub.chainTypeManager(chainId)).isZKsyncOS(),
                string.concat(
                    "core upgrade refused: chain ",
                    vm.toString(chainId),
                    " is on an EraVM chain type manager"
                )
            );
            uint256 protocolVersion = IGetters(bridgehub.getZKChain(chainId)).getProtocolVersion();
            (, uint32 minor, ) = SemVer.unpackSemVer(uint96(protocolVersion));
            require(
                protocolVersion >= MIN_CHAIN_PROTOCOL_VERSION_FOR_CORE_UPGRADE,
                // solhint-disable-next-line func-named-parameters
                string.concat(
                    "core upgrade refused: chain ",
                    vm.toString(chainId),
                    " is on minor version ",
                    vm.toString(uint256(minor)),
                    ", below 33"
                )
            );
        }
    }
}
