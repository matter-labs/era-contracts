// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {Script} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {ChainRegistrationSender} from "contracts/core/chain-registration/ChainRegistrationSender.sol";
import {IMailbox} from "contracts/state-transition/chain-interfaces/IMailbox.sol";
import {IRegisterOnAllChains} from "contracts/script-interfaces/IRegisterOnAllChains.sol";

contract RegisterOnAllChainsScript is Script, IRegisterOnAllChains {
    function registerOnOtherChains(address _bridgehub, uint256 _chainId) public {
        IBridgehubBase bridgehub = IBridgehubBase(_bridgehub);
        uint256[] memory chainsToRegisterOn = bridgehub.getAllZKChainChainIDs();
        ChainRegistrationSender chainRegistrationSender = ChainRegistrationSender(bridgehub.chainRegistrationSender());

        for (uint256 i = 0; i < chainsToRegisterOn.length; i++) {
            if (
                chainRegistrationSender.chainRegisteredOnChain(chainsToRegisterOn[i], _chainId) ||
                !_sameSettlementLayer(bridgehub, chainsToRegisterOn[i], _chainId) ||
                chainsToRegisterOn[i] == _chainId
            ) {
                continue;
            }
            if (!_hasBatchesInMessageRoot(bridgehub, chainsToRegisterOn[i])) {
                _logMissingBatches(chainsToRegisterOn[i], _chainId);
                continue;
            }
            vm.startBroadcast();
            chainRegistrationSender.registerChain(chainsToRegisterOn[i], _chainId);
            vm.stopBroadcast();
        }
        for (uint256 i = 0; i < chainsToRegisterOn.length; i++) {
            if (
                chainRegistrationSender.chainRegisteredOnChain(_chainId, chainsToRegisterOn[i]) ||
                !_sameSettlementLayer(bridgehub, _chainId, chainsToRegisterOn[i]) ||
                chainsToRegisterOn[i] == _chainId
            ) {
                continue;
            }
            if (_depositsPaused(bridgehub, chainsToRegisterOn[i])) {
                console.log(
                    "Info: Deposits are paused on chain:",
                    chainsToRegisterOn[i],
                    ", skipping registration for chain:",
                    _chainId
                );
                continue;
            }
            if (!_hasBatchesInMessageRoot(bridgehub, _chainId)) {
                _logMissingBatches(_chainId, chainsToRegisterOn[i]);
                continue;
            }
            vm.startBroadcast();
            chainRegistrationSender.registerChain(_chainId, chainsToRegisterOn[i]);
            vm.stopBroadcast();
        }
    }

    function _depositsPaused(IBridgehubBase bridgehub, uint256 chainToRegisterOn) internal view returns (bool) {
        address zkChain = bridgehub.getZKChain(chainToRegisterOn);
        IMailbox mailbox = IMailbox(zkChain);
        return mailbox.depositsPaused();
    }

    /// @notice Both chains must settle on the same layer, which is what `ChainRegistrationSender` enforces.
    /// @dev Two chains settling directly on L1 are a legitimate pair: the release this script belongs to
    ///      disables chain migrations altogether (`CHAIN_MIGRATIONS_ENABLED` in `Config.sol`), so L1 is the
    ///      only settlement layer any chain has.
    function _sameSettlementLayer(
        IBridgehubBase bridgehub,
        uint256 chainToBeRegistered,
        uint256 chainToRegisterOn
    ) internal view returns (bool) {
        return bridgehub.settlementLayer(chainToBeRegistered) == bridgehub.settlementLayer(chainToRegisterOn);
    }

    /// @notice Whether the chain already has a batch in this layer's message root.
    /// @dev `ChainRegistrationSender` requires it (`ChainHasNoBatchesInMessageRoot`) so that an interop
    ///      timeout can always be proven against the registered chain. A freshly created ZKsync OS chain
    ///      satisfies it from its genesis root seeding (`MessageRootBase.seedGenesisRoot`), so this only
    ///      skips chains that genuinely have nothing to prove against yet, instead of reverting the run.
    function _hasBatchesInMessageRoot(
        IBridgehubBase bridgehub,
        uint256 chainToBeRegistered
    ) internal view returns (bool) {
        return bridgehub.messageRoot().chainTreeLeafCount(chainToBeRegistered) != 0;
    }

    function _logMissingBatches(uint256 chainToBeRegistered, uint256 chainToRegisterOn) internal pure {
        console.log(
            "Info: Chain has no batches in the message root:",
            chainToBeRegistered,
            ", skipping its registration on chain:",
            chainToRegisterOn
        );
    }
}
