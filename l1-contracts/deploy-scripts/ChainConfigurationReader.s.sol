// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Script, console2 as console} from "forge-std/Script.sol";
import {IZkSyncHyperchain} from "contracts/state-transition/chain-interfaces/IZkSyncHyperchain.sol";
import {PubdataPricingMode} from "contracts/state-transition/chain-deps/ZkSyncHyperchainStorage.sol";
import {StateTransitionManager} from "contracts/state-transition/StateTransitionManager.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";

contract ChainConfigurationReader is Script {
    function run(address stmAddress, uint256 chainId) public view {
        StateTransitionManager stm = StateTransitionManager(stmAddress);
        IZkSyncHyperchain diamondProxy = IZkSyncHyperchain(stm.getHyperchain(chainId));
        address payable chainAdmin = payable(stm.getChainAdmin(chainId));
        address tokenMultiplierSetter = ChainAdmin(chainAdmin).tokenMultiplierSetter();
        address owner = ChainAdmin(chainAdmin).owner();
        address basetoken = diamondProxy.getBaseToken();
        (uint32 major, uint32 minor, uint32 patch) = diamondProxy.getSemverProtocolVersion();
        ValidatorTimelock validatorTimelock = ValidatorTimelock(stm.validatorTimelock());
        PubdataPricingMode pubdataPricingMode = diamondProxy.getPubdataPricingMode();

        uint256 baseTokenGasPriceMultiplierNominator = diamondProxy.baseTokenGasPriceMultiplierNominator();
        uint256 baseTokenGasPriceMultiplierDenominator = diamondProxy.baseTokenGasPriceMultiplierDenominator();

        console.log("=====INFO ABOUT CHAIN %d =====", chainId);
        console.log("Diamond Proxy %s", address(diamondProxy));
        console.log("ChainAdmin %s", chainAdmin);
        console.log("Token Multiplier Setter of ChainAdmin %s", tokenMultiplierSetter);
        console.log("Owner of ChainAdmin %s", owner);
        console.log("Protocol Version %d.%d.%d", major, minor, patch);
        if (pubdataPricingMode == PubdataPricingMode.Validium) {
            console.log("Pubdata Pricing Mode: Validium");
        } else if (pubdataPricingMode == PubdataPricingMode.Rollup) {
            console.log("Pubdata Pricing Mode: Rollup");
        }
        console.log("==BASE TOKEN==");
        console.log("addres: %s", basetoken);
        console.log("nominator: %s", baseTokenGasPriceMultiplierNominator);
        console.log("denominator: %s", baseTokenGasPriceMultiplierDenominator);
    }
}
