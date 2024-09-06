// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StdStorage, stdStorage} from "forge-std/Test.sol";

import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {RegisterHyperchainScript} from "deploy-scripts/RegisterHyperchain.s.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import "@openzeppelin/contracts-v4/utils/Strings.sol";
import {IZkSyncHyperchain} from "contracts/state-transition/chain-interfaces/IZkSyncHyperchain.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {IDiamondInit} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";

contract HyperchainDeployer is L1ContractDeployer {
    using stdStorage for StdStorage;

    RegisterHyperchainScript deployScript;

    struct HyperchainDescription {
        uint256 hyperchainChainId;
        address baseToken;
        uint256 bridgehubCreateNewChainSalt;
        bool validiumMode;
        address validatorSenderOperatorCommitEth;
        address validatorSenderOperatorBlobsEth;
        uint128 baseTokenGasPriceMultiplierNominator;
        uint128 baseTokenGasPriceMultiplierDenominator;
    }

    uint256 currentHyperChainId = 10;
    uint256 eraHyperchainId = 9;
    uint256[] public hyperchainIds;

    function _deployEra() internal {
        vm.setEnv(
            "HYPERCHAIN_CONFIG",
            "/test/foundry/integration/deploy-scripts/script-out/output-deploy-hyperchain-era.toml"
        );

        deployScript = new RegisterHyperchainScript();
        saveHyperchainConfig(_getDefaultDescription(eraHyperchainId, ETH_TOKEN_ADDRESS, eraHyperchainId));
        vm.warp(100);
        deployScript.run();
        hyperchainIds.push(eraHyperchainId);
    }

    function _deployHyperchain(address _baseToken) internal {
        vm.setEnv(
            "HYPERCHAIN_CONFIG",
            string.concat(
                "/test/foundry/integration/deploy-scripts/script-out/output-deploy-hyperchain-",
                Strings.toString(currentHyperChainId),
                ".toml"
            )
        );
        hyperchainIds.push(currentHyperChainId);
        saveHyperchainConfig(_getDefaultDescription(currentHyperChainId, _baseToken, currentHyperChainId));
        currentHyperChainId++;
        deployScript.run();
    }

    function _getDefaultDescription(
        uint256 __chainId,
        address __baseToken,
        uint256 __salt
    ) internal returns (HyperchainDescription memory description) {
        description = HyperchainDescription({
            hyperchainChainId: __chainId,
            baseToken: __baseToken,
            bridgehubCreateNewChainSalt: __salt,
            validiumMode: false,
            validatorSenderOperatorCommitEth: address(0),
            validatorSenderOperatorBlobsEth: address(1),
            baseTokenGasPriceMultiplierNominator: uint128(1),
            baseTokenGasPriceMultiplierDenominator: uint128(1)
        });
    }

    function saveHyperchainConfig(HyperchainDescription memory description) public {
        string memory serialized;

        vm.serializeAddress("toml1", "owner_address", 0x70997970C51812dc3A010C7d01b50e0d17dc79C8);
        vm.serializeUint("chain", "chain_chain_id", description.hyperchainChainId);
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
        string memory path = string.concat(vm.projectRoot(), vm.envString("HYPERCHAIN_CONFIG"));
        vm.writeToml(toml, path);
    }

    function getHyperchainAddress(uint256 _chainId) public view returns (address) {
        return bridgeHub.getHyperchain(_chainId);
    }

    function getHyperchainBaseToken(uint256 _chainId) public view returns (address) {
        return bridgeHub.baseToken(_chainId);
    }

    function acceptPendingAdmin() public {
        IZkSyncHyperchain chain = IZkSyncHyperchain(bridgeHub.getHyperchain(currentHyperChainId - 1));
        address admin = chain.getPendingAdmin();
        vm.startBroadcast(admin);
        chain.acceptAdmin();
        vm.stopBroadcast();
        vm.deal(admin, 10000000000000000000000000);
    }

    // add this to be excluded from coverage report
    function testHyperchainDeployer() internal {}

    function _deployZkChain(
        uint256 _chainId,
        address _baseTokenAddress,
        address _sharedBridge,
        address _admin,
        uint256 _protocolVersion,
        bytes32 _storedBatchZero
    ) internal returns (address) {
        bytes32 baseTokenAssetId = DataEncoding.encodeNTVAssetId(_chainId, _baseTokenAddress);
        Diamond.DiamondCutData memory diamondCut = abi.decode(
            l1Script.getInitialDiamondCutData(),
            (Diamond.DiamondCutData)
        );
        bytes memory initData;

        {
            initData = bytes.concat(
                IDiamondInit.initialize.selector,
                bytes32(_chainId),
                bytes32(uint256(uint160(address(bridgeHub)))),
                bytes32(uint256(uint160(address(this)))),
                bytes32(_protocolVersion),
                bytes32(uint256(uint160(_admin))),
                bytes32(uint256(uint160(address(0x1337)))),
                baseTokenAssetId,
                bytes32(uint256(uint160(_sharedBridge))),
                _storedBatchZero,
                diamondCut.initCalldata
            );
        }
        diamondCut.initCalldata = initData;
        DiamondProxy hyperchainContract = new DiamondProxy{salt: bytes32(0)}(block.chainid, diamondCut);
        return address(hyperchainContract);
    }
}
