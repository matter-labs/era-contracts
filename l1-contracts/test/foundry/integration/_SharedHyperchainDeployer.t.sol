// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {RegisterHyperchainsScript} from "../../../scripts-rs/script/RegisterHyperchains.s.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";

contract HyperchainDeployer is L1ContractDeployer {
    RegisterHyperchainsScript deployScript;
    HyperchainDeployInfo[] hyperchainsToDeploy;

    struct HyperchainDeployInfo {
        string name;
        uint256 chainId;
        address baseToken;
    }

    uint256 currentHyperChainId = 9;
    uint256[] hyperchainIds;

    function deployHyperchains() internal {
        deployScript = new RegisterHyperchainsScript();

        hyperchainsToDeploy.push(
            HyperchainDeployInfo({name: "era", chainId: currentHyperChainId, baseToken: ETH_TOKEN_ADDRESS})
        );

        saveHyperchainConfig();

        vm.setEnv("HYPERCHAINS_CONFIG", "/scripts-rs/script-out/output-deploy-hyperchains.toml");

        deployScript.run();
    }

    function saveHyperchainConfig() public {
        string memory serialized;

        for (uint256 i = 0; i < hyperchainsToDeploy.length; i++) {
            HyperchainDeployInfo memory info = hyperchainsToDeploy[i];

            RegisterHyperchainsScript.HyperchainDescription memory description = RegisterHyperchainsScript
                .HyperchainDescription({
                    hyperchainChainId: info.chainId,
                    baseToken: info.baseToken,
                    bridgehubCreateNewChainSalt: 0,
                    validiumMode: false,
                    validatorSenderOperatorCommitEth: address(0),
                    validatorSenderOperatorBlobsEth: address(1),
                    baseTokenGasPriceMultiplierNominator: uint128(1),
                    baseTokenGasPriceMultiplierDenominator: uint128(1)
                });

            string memory hyperchainName = info.name;

            vm.serializeUint(hyperchainName, "hyperchain_chain_id", description.hyperchainChainId);
            vm.serializeAddress(hyperchainName, "base_token_addr", description.baseToken);
            vm.serializeUint(
                hyperchainName,
                "bridgehub_create_new_chain_salt",
                description.bridgehubCreateNewChainSalt
            );

            uint256 validiumMode = 0;

            if (description.validiumMode) {
                validiumMode = 1;
            }

            vm.serializeUint(hyperchainName, "validium_mode", validiumMode);

            vm.serializeAddress(
                hyperchainName,
                "validator_sender_operator_commit_eth",
                description.validatorSenderOperatorCommitEth
            );
            vm.serializeAddress(
                hyperchainName,
                "validator_sender_operator_blobs_eth",
                description.validatorSenderOperatorBlobsEth
            );
            vm.serializeUint(
                hyperchainName,
                "base_token_gas_price_multiplier_nominator",
                description.baseTokenGasPriceMultiplierNominator
            );

            string memory single_serialized = vm.serializeUint(
                hyperchainName,
                "base_token_gas_price_multiplier_denominator",
                description.baseTokenGasPriceMultiplierDenominator
            );

            serialized = vm.serializeString("hyperchain", hyperchainName, single_serialized);
        }

        string memory toml = vm.serializeString("toml1", "hyperchains", serialized);
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/scripts-rs/script-out/output-deploy-hyperchains.toml");
        vm.writeToml(toml, path);
    }

    function getHyperchainAddress(uint256 _chainId) public view returns (address) {
        return bridgeHub.getHyperchain(_chainId);
    }

    function getHyperchainBaseToken(uint256 _chainId) public view returns (address) {
        return bridgeHub.baseToken(_chainId);
    }
}
