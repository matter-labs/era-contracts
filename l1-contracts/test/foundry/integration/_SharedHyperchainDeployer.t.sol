// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {RegisterHyperchainsScript} from "./deploy-scripts/script/RegisterHyperchains.s.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";

contract HyperchainDeployer is L1ContractDeployer {
    RegisterHyperchainsScript deployScript;
    HyperchainDeployInfo[] hyperchainsToDeploy;

    struct HyperchainDeployInfo {
        string name;
        RegisterHyperchainsScript.HyperchainDescription description;
    }

    uint256 currentHyperChainId = 10;
    uint256 eraHyperchainId = 9;
    uint256[] public hyperchainIds;

    function _deployHyperchains() internal {
        deployScript = new RegisterHyperchainsScript();

        hyperchainsToDeploy.push(_getDefaultHyperchainDeployInfo("era", eraHyperchainId, ETH_TOKEN_ADDRESS));
        hyperchainIds.push(eraHyperchainId);

        saveHyperchainConfig();

        vm.setEnv(
            "HYPERCHAINS_CONFIG",
            "/test/foundry/integration/deploy-scripts/script-out/output-deploy-hyperchains.toml"
        );

        deployScript.run();
    }

    function _addNewHyperchainToDeploy(string memory _name, address _baseToken) internal {
        hyperchainsToDeploy.push(_getDefaultHyperchainDeployInfo(_name, currentHyperChainId, _baseToken));
        hyperchainIds.push(currentHyperChainId);
        currentHyperChainId++;
    }

    function _getDefaultDescription(
        uint256 __chainId,
        address __baseToken
    ) internal returns (RegisterHyperchainsScript.HyperchainDescription memory description) {
        description = RegisterHyperchainsScript.HyperchainDescription({
            hyperchainChainId: __chainId,
            baseToken: __baseToken,
            bridgehubCreateNewChainSalt: 0,
            validiumMode: false,
            validatorSenderOperatorCommitEth: address(0),
            validatorSenderOperatorBlobsEth: address(1),
            baseTokenGasPriceMultiplierNominator: uint128(1),
            baseTokenGasPriceMultiplierDenominator: uint128(1)
        });
    }

    function _getDefaultHyperchainDeployInfo(
        string memory __name,
        uint256 __chainId,
        address __baseToken
    ) internal returns (HyperchainDeployInfo memory deployInfo) {
        deployInfo = HyperchainDeployInfo({name: __name, description: _getDefaultDescription(__chainId, __baseToken)});
    }

    function saveHyperchainConfig() public {
        string memory serialized;

        for (uint256 i = 0; i < hyperchainsToDeploy.length; i++) {
            HyperchainDeployInfo memory info = hyperchainsToDeploy[i];
            RegisterHyperchainsScript.HyperchainDescription memory description = info.description;
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
        string memory path = string.concat(
            root,
            "/test/foundry/integration/deploy-scripts/script-out/output-deploy-hyperchains.toml"
        );
        vm.writeToml(toml, path);
    }

    function getHyperchainAddress(uint256 _chainId) public view returns (address) {
        return bridgeHub.getHyperchain(_chainId);
    }

    function getHyperchainBaseToken(uint256 _chainId) public view returns (address) {
        return bridgeHub.baseToken(_chainId);
    }
}
