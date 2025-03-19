// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {ChainRegistrar} from "contracts/chain-registrar/ChainRegistrar.sol";
import {PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {ADDRESS_ONE} from "./Utils.sol";

contract ProposeChainRegistration is Script {
    using stdToml for string;

    // solhint-disable-next-line gas-struct-packing
    struct Config {
        address chainRegistrar;
        ChainRegistrar.ChainConfig chainConfig;
    }

    Config config;

    function run() external {
        initializeConfig();
        approveBaseToken();
        proposeRegistration();
    }

    function initializeConfig() internal {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/script-config/config-propose-chain-registration.toml");
        string memory toml = vm.readFile(path);

        // Config file must be parsed key by key, otherwise values returned
        // are parsed alfabetically and not by key.
        // https://book.getfoundry.sh/cheatcodes/parse-toml
        config.chainRegistrar = toml.readAddress("$.chain_registrar");

        config.chainConfig.chainId = toml.readUint("$.chain.chain_id");
        config.chainConfig.operator = toml.readAddress("$.chain.operator");
        config.chainConfig.blobOperator = toml.readAddress("$.chain.blob_operator");
        config.chainConfig.governor = toml.readAddress("$.chain.governor");
        config.chainConfig.pubdataPricingMode = PubdataPricingMode(toml.readUint("$.chain.pubdata_pricing_mode"));

        config.chainConfig.baseToken.tokenMultiplierSetter = toml.readAddress(
            "$.chain.base_token.token_multiplier_setter"
        );
        config.chainConfig.baseToken.tokenAddress = toml.readAddress("$.chain.base_token.address");
        config.chainConfig.baseToken.gasPriceMultiplierNominator = uint128(
            toml.readUint("$.chain.base_token.nominator")
        );
        config.chainConfig.baseToken.gasPriceMultiplierDenominator = uint128(
            toml.readUint("$.chain.base_token.denominator")
        );
    }

    function approveBaseToken() internal {
        if (config.chainConfig.baseToken.tokenAddress == ADDRESS_ONE) {
            return;
        }
        uint256 amount = (1 ether * config.chainConfig.baseToken.gasPriceMultiplierNominator) /
            config.chainConfig.baseToken.gasPriceMultiplierDenominator;

        vm.broadcast();
        IERC20(config.chainConfig.baseToken.tokenAddress).approve(config.chainRegistrar, amount);
    }

    function proposeRegistration() internal {
        ChainRegistrar chain_registrar = ChainRegistrar(config.chainRegistrar);
        vm.broadcast();
        chain_registrar.proposeChainRegistration(
            config.chainConfig.chainId,
            config.chainConfig.pubdataPricingMode,
            config.chainConfig.blobOperator,
            config.chainConfig.operator,
            config.chainConfig.governor,
            config.chainConfig.baseToken.tokenAddress,
            config.chainConfig.baseToken.tokenMultiplierSetter,
            config.chainConfig.baseToken.gasPriceMultiplierNominator,
            config.chainConfig.baseToken.gasPriceMultiplierDenominator
        );
    }
}
