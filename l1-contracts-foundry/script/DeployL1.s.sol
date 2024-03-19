// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {Script, console2 as console} from "forge-std/Script.sol";
import {Multicall3} from "contracts/dev-contracts/Multicall3.sol";
import {SingletonFactory} from "contracts/dev-contracts/SingletonFactory.sol";
import {Verifier} from "contracts/zksync/Verifier.sol";
import {DiamondUpgradeInit1} from "contracts/zksync/upgrade-initializers/DiamondUpgradeInit1.sol";
import {DiamondUpgradeInit2} from "contracts/zksync/upgrade-initializers/DiamondUpgradeInit2.sol";
import {DiamondUpgradeInit3} from "contracts/zksync/upgrade-initializers/DiamondUpgradeInit3.sol";
import {DiamondUpgradeInit4} from "contracts/zksync/upgrade-initializers/DiamondUpgradeInit4.sol";
import {DiamondUpgradeInit5} from "contracts/zksync/upgrade-initializers/DiamondUpgradeInit5.sol";
import {DiamondUpgradeInit6} from "contracts/zksync/upgrade-initializers/DiamondUpgradeInit6.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {Governance} from "contracts/governance/Governance.sol";

contract DeployL1Script is Script {
    uint256 deployerPrivateKey;
    bytes32 create2Salt;
    SingletonFactory create2Factory;

    function run() public {
        console.log("Deploying L1 contracts");

        deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        console.log("Using deployer wallet:", vm.addr(deployerPrivateKey));

        uint256 gasPrice = vm.envOr("GAS_PRICE", uint256(0));
        if (gasPrice != 0) {
            vm.txGasPrice(gasPrice);
            console.log("Using gas price:", gasPrice);
        } else {
            console.log("Using provider's gas price"); //TODO: retrieve from provider
        }

        // FIXME: nonce cannot be set from foundry
        // uint256 nonce = vm.envOr("NONCE", uint256(0));
        // if (nonce != 0) {
        //     vm.setNonce(account, newNonce);(nonce);
        //     console.log("Using nonce:", nonce);
        // } else {
        //     console.log("Using provider's nonce"); //TODO: retrieve from provider
        // }

        create2Salt = vm.envBytes32("CONTRACTS_CREATE2_FACTORY_SALT");

        // Create2 factory already deployed on the public networks, only deploy it on local node
        address create2FactoryAddress;
        string memory network = vm.envString("CHAIN_ETH_NETWORK");
        if (keccak256(abi.encodePacked(network)) == keccak256(abi.encodePacked("local"))) {
            create2FactoryAddress = deployCreate2Factory();
        } else {
            create2FactoryAddress = vm.envAddress("CONTRACTS_CREATE2_FACTORY_ADDR");
        }
        console.log("Using Create2Factory address:", create2FactoryAddress);
        create2Factory = SingletonFactory(create2FactoryAddress);

        deployMulticall3();

        if (vm.envOr("ONLY_VERIFIER", false)) {
            deployVerifier();
            return;
        }

        // Deploy diamond upgrade init contract if needed
        uint256 diamondUpgradeContractVersion = vm.envOr("DIAMOND_UPGRADE_CONTRACT_VERSION", uint256(1));
        if (diamondUpgradeContractVersion >= 1) {
            deployDiamondUpgradeInit(diamondUpgradeContractVersion);
        }

        deployDefaultUpgrade();
    }

    function deployCreate2Factory() internal returns (address) {
        vm.broadcast(deployerPrivateKey);
        SingletonFactory factory = new SingletonFactory();
        console.log("Create2Factory deployed at:", address(factory));
        return address(factory);
    }

    function deployMulticall3() internal {
        bytes memory multicall3Bytecode = type(Multicall3).creationCode;

        vm.broadcast(deployerPrivateKey);
        address multicall3Address = create2Factory.deploy(multicall3Bytecode, create2Salt);

        console.log("Multicall3 deployed at:", multicall3Address);
    }

    function deployVerifier() internal {
        bytes memory verifierBytecode = type(Verifier).creationCode;

        vm.broadcast(deployerPrivateKey);
        address verifierAddress = create2Factory.deploy(verifierBytecode, create2Salt);

        console.log("Verifier deployed at:", verifierAddress);
    }

    function deployDiamondUpgradeInit(uint256 version) internal {
        bytes memory diamondUpdateBytecode;
        if (version == 1) {
            diamondUpdateBytecode = type(DiamondUpgradeInit1).creationCode;
        } else if (version == 2) {
            diamondUpdateBytecode = type(DiamondUpgradeInit2).creationCode;
        } else if (version == 3) {
            diamondUpdateBytecode = type(DiamondUpgradeInit3).creationCode;
        } else if (version == 4) {
            diamondUpdateBytecode = type(DiamondUpgradeInit4).creationCode;
        } else if (version == 5) {
            diamondUpdateBytecode = type(DiamondUpgradeInit5).creationCode;
        } else if (version == 6) {
            diamondUpdateBytecode = type(DiamondUpgradeInit6).creationCode;
        } else {
            revert("Invalid diamond upgrade contract version");
        }

        vm.broadcast(deployerPrivateKey);
        address diamondUpgradeInitAddress = create2Factory.deploy(diamondUpdateBytecode, create2Salt);

        console.log("DiamondUpgradeInit version %s deployed at: %s", version, verifierAddress);
    }

    function deployDefaultUpgrade() internal {
        bytes memory defaultUpgradeBytecode = type(DefaultUpgrade).creationCode;

        vm.broadcast(deployerPrivateKey);
        address defaultUpgradeAddress = create2Factory.deploy(defaultUpgradeBytecode, create2Salt);

        console.log("DefaultUpgrade deployed at:", defaultUpgradeAddress);
    }

    function deployBlobVersionedHashRetriever() internal {
        // solc contracts/zksync/utils/blobVersionedHashRetriever.yul --strict-assembly --bin
        bytes memory bytecode = abi.encodePacked(hex"600b600b5f39600b5ff3fe5f358049805f5260205ff3");

        vm.broadcast(deployerPrivateKey);
        address blobVersionedHashRetrieverAddress = create2Factory.deploy(bytecode, create2Salt);

        console.log("BlobVersionedHashRetriever deployed at:", blobVersionedHashRetrieverAddress);
    }

    function deployGovernance() internal {
        bytes memory governanceBytecode = type(Governance).creationCode;

        vm.broadcast(deployerPrivateKey);
        address governanceAddress = create2Factory.deploy(governanceBytecode, create2Salt);

        console.log("Governance deployed at:", governanceAddress);
    }

    function deployZkSyncContract() internal {
        // TODO
    }
}
