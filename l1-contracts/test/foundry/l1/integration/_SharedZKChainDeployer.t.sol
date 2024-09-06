// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
<<<<<<<< HEAD:l1-contracts/test/foundry/l1/integration/_SharedHyperchainDeployer.t.sol
import {RegisterHyperchainScript} from "deploy-scripts/RegisterHyperchain.s.sol";
import {BASE_TOKEN_VIRTUAL_ADDRESS} from "contracts/common/Config.sol";
========
import {RegisterZKChainScript} from "deploy-scripts/RegisterZKChain.s.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
>>>>>>>> cb42ae402af3e3f676003f44a49da4ea37a6811c:l1-contracts/test/foundry/l1/integration/_SharedZKChainDeployer.t.sol
import "@openzeppelin/contracts-v4/utils/Strings.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";

contract ZKChainDeployer is L1ContractDeployer {
    RegisterZKChainScript deployScript;

    struct ZKChainDescription {
        uint256 zkChainChainId;
        address baseToken;
        uint256 bridgehubCreateNewChainSalt;
        bool validiumMode;
        address validatorSenderOperatorCommitEth;
        address validatorSenderOperatorBlobsEth;
        uint128 baseTokenGasPriceMultiplierNominator;
        uint128 baseTokenGasPriceMultiplierDenominator;
    }

    uint256 currentZKChainId = 10;
    uint256 eraZKChainId = 9;
    uint256[] public zkChainIds;

    function _deployEra() internal {
        vm.setEnv(
<<<<<<<< HEAD:l1-contracts/test/foundry/l1/integration/_SharedHyperchainDeployer.t.sol
            "HYPERCHAIN_CONFIG",
            "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-hyperchain-era.toml"
        );

        deployScript = new RegisterHyperchainScript();
        saveHyperchainConfig(_getDefaultDescription(eraHyperchainId, BASE_TOKEN_VIRTUAL_ADDRESS, eraHyperchainId));
========
            "ZK_CHAIN_CONFIG",
            "/test/foundry/integration/deploy-scripts/script-out/output-deploy-zk-chain-era.toml"
        );

        deployScript = new RegisterZKChainScript();
        saveZKChainConfig(_getDefaultDescription(eraZKChainId, ETH_TOKEN_ADDRESS, eraZKChainId));
>>>>>>>> cb42ae402af3e3f676003f44a49da4ea37a6811c:l1-contracts/test/foundry/l1/integration/_SharedZKChainDeployer.t.sol
        vm.warp(100);
        deployScript.run();
        zkChainIds.push(eraZKChainId);
    }

    function _deployZKChain(address _baseToken) internal {
        vm.setEnv(
            "ZK_CHAIN_CONFIG",
            string.concat(
<<<<<<<< HEAD:l1-contracts/test/foundry/l1/integration/_SharedHyperchainDeployer.t.sol
                "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-hyperchain-",
                Strings.toString(currentHyperChainId),
========
                "/test/foundry/integration/deploy-scripts/script-out/output-deploy-zk-chain-",
                Strings.toString(currentZKChainId),
>>>>>>>> cb42ae402af3e3f676003f44a49da4ea37a6811c:l1-contracts/test/foundry/l1/integration/_SharedZKChainDeployer.t.sol
                ".toml"
            )
        );
        zkChainIds.push(currentZKChainId);
        saveZKChainConfig(_getDefaultDescription(currentZKChainId, _baseToken, currentZKChainId));
        currentZKChainId++;
        deployScript.run();
    }

    function _getDefaultDescription(
        uint256 __chainId,
        address __baseToken,
        uint256 __salt
    ) internal returns (ZKChainDescription memory description) {
        description = ZKChainDescription({
            zkChainChainId: __chainId,
            baseToken: __baseToken,
            bridgehubCreateNewChainSalt: __salt,
            validiumMode: false,
            validatorSenderOperatorCommitEth: address(0),
            validatorSenderOperatorBlobsEth: address(1),
            baseTokenGasPriceMultiplierNominator: uint128(1),
            baseTokenGasPriceMultiplierDenominator: uint128(1)
        });
    }

    function saveZKChainConfig(ZKChainDescription memory description) public {
        string memory serialized;

        vm.serializeAddress("toml1", "owner_address", 0x70997970C51812dc3A010C7d01b50e0d17dc79C8);
        vm.serializeUint("chain", "chain_chain_id", description.zkChainChainId);
        vm.serializeAddress("chain", "base_token_addr", description.baseToken);
        vm.serializeUint("chain", "bridgehub_create_new_chain_salt", description.bridgehubCreateNewChainSalt);

        uint256 validiumMode = 0;

        if (description.validiumMode) {
            validiumMode = 1;
        }

        vm.serializeUint("chain", "validium_mode", validiumMode);
        vm.serializeAddress(
            "chain",
            "validator_sender_operator_commit_eth",
            description.validatorSenderOperatorCommitEth
        );
        vm.serializeAddress(
            "chain",
            "validator_sender_operator_blobs_eth",
            description.validatorSenderOperatorBlobsEth
        );
        vm.serializeUint(
            "chain",
            "base_token_gas_price_multiplier_nominator",
            description.baseTokenGasPriceMultiplierNominator
        );
        vm.serializeUint("chain", "governance_min_delay", 0);
        vm.serializeAddress("chain", "governance_security_council_address", address(0));

        string memory single_serialized = vm.serializeUint(
            "chain",
            "base_token_gas_price_multiplier_denominator",
            description.baseTokenGasPriceMultiplierDenominator
        );

        string memory toml = vm.serializeString("toml1", "chain", single_serialized);
        string memory path = string.concat(vm.projectRoot(), vm.envString("ZK_CHAIN_CONFIG"));
        vm.writeToml(toml, path);
    }

    function getZKChainAddress(uint256 _chainId) public view returns (address) {
        return bridgeHub.getZKChain(_chainId);
    }

    function getZKChainBaseToken(uint256 _chainId) public view returns (address) {
        return bridgeHub.baseToken(_chainId);
    }

    function acceptPendingAdmin() public {
        IZKChain chain = IZKChain(bridgeHub.getZKChain(currentZKChainId - 1));
        address admin = chain.getPendingAdmin();
        vm.startBroadcast(admin);
        chain.acceptAdmin();
        vm.stopBroadcast();
        vm.deal(admin, 10000000000000000000000000);
    }

    // add this to be excluded from coverage report
    function testZKChainDeployer() internal {}
}
