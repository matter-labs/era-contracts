// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdStorage, stdStorage} from "forge-std/Test.sol";

import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {RegisterZKChainScript} from "deploy-scripts/ctm/RegisterZKChain.s.sol";
import {RegisterZKChainConfig as ChainConfig} from "contracts/script-interfaces/IRegisterZKChain.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";

import "@openzeppelin/contracts-v4/utils/Strings.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {IDiamondInit} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IMigrator} from "contracts/state-transition/chain-interfaces/IMigrator.sol";
import {L2DACommitmentScheme} from "contracts/common/Config.sol";

contract ZKChainDeployer is L1ContractDeployer {
    using stdStorage for StdStorage;

    RegisterZKChainScript deployScript;

    struct ZKChainDescription {
        uint256 zkChainChainId;
        address baseToken;
        uint256 bridgehubCreateNewChainSalt;
        bool validiumMode;
        address validatorSenderOperatorEth;
        address validatorSenderOperatorBlobsEth;
        address validatorSenderOperatorProve;
        address validatorSenderOperatorExecute;
        uint128 baseTokenGasPriceMultiplierNominator;
        uint128 baseTokenGasPriceMultiplierDenominator;
        bool allowEvmEmulator;
    }

    ChainConfig internal eraConfig;

    uint256 currentZKChainId = 10;
    uint256 eraZKChainId = 9;
    uint256[] public zkChainIds;

    function _deployEra() internal {
        _deployEraDeposits(false);
    }

    function _deployEraWithPausedDeposits() internal {
        _deployEraDeposits(true);
    }

    function _deployEraDeposits(bool _pausedDeposits) internal {
        vm.setEnv(
            "ZK_CHAIN_CONFIG",
            "/test/foundry/l1/integration/deploy-scripts/script-config/config-deploy-zk-chain-era.toml"
        );
        vm.setEnv(
            "ZK_CHAIN_OUT",
            "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-zk-chain-era.toml"
        );
        deployScript = new RegisterZKChainScript();
        vm.warp(100);

        _deployZKChainShared(eraZKChainId, ETH_TOKEN_ADDRESS);

        address chainAddress = getZKChainAddress(eraZKChainId);
        if (!_pausedDeposits) {
            IMigrator(chainAddress).unpauseDeposits();
        }
        eraConfig = deployScript.getConfig();
    }

    function _deployZKChain(address _baseToken) internal {
        _deployZKChain(_baseToken, 0);
    }

    function _deployZKChain(address _baseToken, uint256 _chainId) internal {
        uint256 chainId = _deployZKChainInner(_baseToken, _chainId);

        address chainAddress = getZKChainAddress(chainId);
        IMigrator(chainAddress).unpauseDeposits();
    }

    function _deployZKChainWithPausedDeposits(address _baseToken, uint256 _chainId) internal {
        _deployZKChainInner(_baseToken, _chainId);
    }

    function _deployZKChainInner(address _baseToken, uint256 _chainId) internal returns (uint256 chainId) {
        chainId = _chainId == 0 ? currentZKChainId : _chainId;
        vm.setEnv(
            "ZK_CHAIN_CONFIG",
            string.concat(
                "/test/foundry/l1/integration/deploy-scripts/script-config/config-deploy-zk-chain-",
                Strings.toString(chainId),
                ".toml"
            )
        );
        vm.setEnv(
            "ZK_CHAIN_OUT",
            string.concat(
                "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-zk-chain-",
                Strings.toString(chainId),
                ".toml"
            )
        );
        if (chainId == currentZKChainId) {
            currentZKChainId++;
        }
        _deployZKChainShared(chainId, _baseToken);
    }

    function _deployZKChainShared(uint256 _chainId, address _baseToken) internal {
        saveZKChainConfig(_getDefaultDescription(_chainId, _baseToken, _chainId));
        zkChainIds.push(_chainId);
        deployScript.runForTest(address(addresses.chainTypeManager), _chainId);
        _setDAValidatorPair(_chainId);
        _processGenesisUpgrade(_chainId);
    }

    function _processGenesisUpgrade(uint256 _chainId) internal {
        IZKChain chain = IZKChain(addresses.bridgehub.getZKChain(_chainId));
        // Slot 34 is "l2SystemContractsUpgradeBatchNumber" in ZKChainStorage
        vm.store(address(chain), bytes32(uint256(34)), bytes32(0));
    }

    function _setDAValidatorPair(uint256 _chainId) internal {
        IZKChain chain = IZKChain(addresses.bridgehub.getZKChain(_chainId));
        address admin = chain.getAdmin();
        vm.startBroadcast(admin);
        chain.setDAValidatorPair(
            ctmAddresses.daAddresses.l1RollupDAValidator,
            L2DACommitmentScheme.BLOBS_AND_PUBDATA_KECCAK256
        );
        vm.stopBroadcast();
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
            validatorSenderOperatorEth: address(0),
            validatorSenderOperatorBlobsEth: address(1),
            validatorSenderOperatorProve: address(2),
            validatorSenderOperatorExecute: address(3),
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
        vm.serializeAddress("chain", "validator_sender_operator_eth", description.validatorSenderOperatorEth);
        vm.serializeAddress(
            "chain",
            "validator_sender_operator_blobs_eth",
            description.validatorSenderOperatorBlobsEth
        );
        vm.serializeAddress("chain", "validator_sender_operator_prove", description.validatorSenderOperatorProve);
        vm.serializeAddress("chain", "validator_sender_operator_execute", description.validatorSenderOperatorExecute);
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
        acceptPendingAdmin(0);
    }

    function acceptPendingAdmin(uint256 _chainId) public {
        uint256 chainId = _chainId == 0 ? currentZKChainId - 1 : _chainId;
        IZKChain chain = IZKChain(addresses.bridgehub.getZKChain(chainId));
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
        address _bridgehub,
        address _interopCenter,
        address _chainTypeManager
    ) internal returns (address) {
        Diamond.DiamondCutData memory diamondCut = abi.decode(
            ecosystemConfig.contracts.diamondCutData,
            (Diamond.DiamondCutData)
        );
        bytes memory initData1;
        bytes memory initData2;

        {
            // stack too deep
            initData1 = bytes.concat(
                IDiamondInit.initialize.selector,
                bytes32(_chainId),
                bytes32(uint256(uint160(address(_bridgehub)))),
                bytes32(uint256(uint160(address(_interopCenter)))),
                bytes32(uint256(uint160(_chainTypeManager)))
            );
        }
        {
            initData2 = bytes.concat(
                bytes32(_protocolVersion),
                bytes32(uint256(uint160(_admin))),
                bytes32(uint256(uint160(address(0x1337)))),
                _baseTokenAssetId,
                _storedBatchZero,
                diamondCut.initCalldata
            );
        }
        bytes memory initData;
        {
            initData = bytes.concat(initData1, initData2);
        }

        diamondCut.initCalldata = initData;
        DiamondProxy hyperchainContract = new DiamondProxy{salt: bytes32(0)}(block.chainid, diamondCut);
        return address(hyperchainContract);
    }
}
