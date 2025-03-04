// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StdStorage, stdStorage} from "forge-std/Test.sol";

import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {RegisterZKChainScript} from "deploy-scripts/RegisterZKChain.s.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import "@openzeppelin/contracts-v4/utils/Strings.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {IDiamondInit} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";

import {Config as ChainConfig} from "deploy-scripts/RegisterZKChain.s.sol";

contract ZKChainDeployer is L1ContractDeployer {
    using stdStorage for StdStorage;

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
        bool allowEvmEmulator;
    }

    ChainConfig internal eraConfig;

    uint256 currentZKChainId = 10;
    uint256 eraZKChainId = 9;
    uint256[] public zkChainIds;

    function _deployEra() internal {
        vm.setEnv(
            "ZK_CHAIN_CONFIG",
            "/test/foundry/l1/integration/deploy-scripts/script-config/config-deploy-zk-chain-era.toml"
        );
        vm.setEnv(
            "ZK_CHAIN_OUT",
            "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-zk-chain-era.toml"
        );
        deployScript = new RegisterZKChainScript();
        saveZKChainConfig(_getDefaultDescription(eraZKChainId, ETH_TOKEN_ADDRESS, eraZKChainId));
        vm.warp(100);
        deployScript.runForTest();
        zkChainIds.push(eraZKChainId);
        eraConfig = deployScript.getConfig();
    }

    function _deployZKChain(address _baseToken) internal {
        vm.setEnv(
            "ZK_CHAIN_CONFIG",
            string.concat(
                "/test/foundry/l1/integration/deploy-scripts/script-config/config-deploy-zk-chain-",
                Strings.toString(currentZKChainId),
                ".toml"
            )
        );
        vm.setEnv(
            "ZK_CHAIN_OUT",
            string.concat(
                "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-zk-chain-",
                Strings.toString(currentZKChainId),
                ".toml"
            )
        );
        zkChainIds.push(currentZKChainId);
        saveZKChainConfig(_getDefaultDescription(currentZKChainId, _baseToken, currentZKChainId));
        currentZKChainId++;
        deployScript.runForTest();
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
            baseTokenGasPriceMultiplierDenominator: uint128(1),
            allowEvmEmulator: false
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

        vm.serializeBool("chain", "allow_evm_emulator", description.allowEvmEmulator);

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
        return addresses.bridgehub.getZKChain(_chainId);
    }

    function getZKChainBaseToken(uint256 _chainId) public view returns (address) {
        return addresses.bridgehub.baseToken(_chainId);
    }

    function acceptPendingAdmin() public {
        IZKChain chain = IZKChain(addresses.bridgehub.getZKChain(currentZKChainId - 1));
        address admin = chain.getPendingAdmin();
        vm.startBroadcast(admin);
        chain.acceptAdmin();
        vm.stopBroadcast();
        vm.deal(admin, 10000000000000000000000000);
    }

    // add this to be excluded from coverage report
    function testZKChainDeployer() internal {}

    function _deployZkChain(
        uint256 _chainId,
        bytes32 _baseTokenAssetId,
        address _admin,
        uint256 _protocolVersion,
        bytes32 _storedBatchZero,
        address _bridgehub
    ) internal returns (address) {
        Diamond.DiamondCutData memory diamondCut = abi.decode(
            ecosystemConfig.contracts.diamondCutData,
            (Diamond.DiamondCutData)
        );
        bytes memory initData;

        {
            initData = bytes.concat(
                IDiamondInit.initialize.selector,
                bytes32(_chainId),
                bytes32(uint256(uint160(address(_bridgehub)))),
                bytes32(uint256(uint160(address(this)))),
                bytes32(_protocolVersion),
                bytes32(uint256(uint160(_admin))),
                bytes32(uint256(uint160(address(0x1337)))),
                _baseTokenAssetId,
                _storedBatchZero,
                diamondCut.initCalldata
            );
        }
        diamondCut.initCalldata = initData;
        DiamondProxy hyperchainContract = new DiamondProxy{salt: bytes32(0)}(block.chainid, diamondCut);
        return address(hyperchainContract);
    }
}
