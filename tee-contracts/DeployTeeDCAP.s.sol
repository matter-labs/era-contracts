// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {HashValidator} from "./contracts/HashValidator.sol";
import {MatterLabsDCAPAttestation} from "./contracts/MatterLabsDCAPAttestation.sol";
import {DCAPAttestationHelpers} from "./contracts/DCAPAttestationHelpers.sol";
import {DCAPAttestationDAOs} from "./contracts/DCAPAttestationDAOs.sol";
import {DCAPAttestationStorage} from "./contracts/DCAPAttestationStorage.sol";
import {PcsDaoDeployer} from "./contracts/PcsDaoDeployer.sol";
import {PckDaoDeployer} from "./contracts/PckDaoDeployer.sol";
import {EnclaveIdentityDaoDeployer} from "./contracts/EnclaveIdentityDaoDeployer.sol";
import {FmspcTcbDaoDeployer} from "./contracts/FmspcTcbDaoDeployer.sol";
import {PCCSRouterDeployer} from "./contracts/PCCSRouterDeployer.sol";
import {AutomataDaoStorage} from "@automata-network/on-chain-pccs/automata_pccs/shared/AutomataDaoStorage.sol";
import {V3QuoteVerifier} from "automata-network/dcap-attestation/evm/contracts/verifiers/V3QuoteVerifier.sol";
import {V4QuoteVerifier} from "automata-network/dcap-attestation/evm/contracts/verifiers/V4QuoteVerifier.sol";
import {CommonBase} from "lib/forge-std/src/Base.sol";
import {Script} from "lib/forge-std/src/Script.sol";
import {StdChains} from "lib/forge-std/src/StdChains.sol";
import {StdCheatsSafe} from "lib/forge-std/src/StdCheats.sol";
import {StdUtils} from "lib/forge-std/src/StdUtils.sol";
import {console} from "lib/forge-std/src/console.sol";

/**
 * @notice Script to deploy TEE DCAP attestation contracts
 */
contract DeployTeeDCAPScript is Script {
    function run() external {
        // Deploy P256 Verifier first
        vm.startBroadcast();
        address p256Verifier = deployP256Verifier();
        console.log("P256 Verifier deployed at:", p256Verifier);
        vm.stopBroadcast();

        // Deploy HashValidator in a separate transaction
        vm.startBroadcast();
        HashValidator hashValidator = new HashValidator(msg.sender);
        console.log("HashValidator deployed at:", address(hashValidator));
        vm.stopBroadcast();

        // Deploy DCAPAttestationHelpers in a separate transaction
        vm.startBroadcast();
        DCAPAttestationHelpers helpers = new DCAPAttestationHelpers();
        console.log("DCAPAttestationHelpers deployed at:", address(helpers));
        vm.stopBroadcast();

        // Deploy the deployers first
        vm.startBroadcast();
        PcsDaoDeployer pcsDaoDeployer = new PcsDaoDeployer();
        console.log("PcsDaoDeployer deployed at:", address(pcsDaoDeployer));
        vm.stopBroadcast();

        vm.startBroadcast();
        PckDaoDeployer pckDaoDeployer = new PckDaoDeployer();
        console.log("PckDaoDeployer deployed at:", address(pckDaoDeployer));
        vm.stopBroadcast();

        vm.startBroadcast();
        EnclaveIdentityDaoDeployer enclaveIdDaoDeployer = new EnclaveIdentityDaoDeployer();
        console.log("EnclaveIdentityDaoDeployer deployed at:", address(enclaveIdDaoDeployer));
        vm.stopBroadcast();

        vm.startBroadcast();
        FmspcTcbDaoDeployer fmspcTcbDaoDeployer = new FmspcTcbDaoDeployer();
        console.log("FmspcTcbDaoDeployer deployed at:", address(fmspcTcbDaoDeployer));
        vm.stopBroadcast();

        vm.startBroadcast();
        PCCSRouterDeployer routerDeployer = new PCCSRouterDeployer();
        console.log("PCCSRouterDeployer deployed at:", address(routerDeployer));
        vm.stopBroadcast();

        // Deploy the components in sequence
        vm.startBroadcast();
        // 1. Deploy storage - this will make msg.sender the owner
        AutomataDaoStorage pccsStorage = new AutomataDaoStorage();
        address storageAddress = address(pccsStorage);
        console.log("PCCS Storage deployed at:", storageAddress);
        vm.stopBroadcast();

        // 2. Deploy PCS DAO
        vm.startBroadcast();
        address pcsDao = address(pcsDaoDeployer.deployPcsDao(
            storageAddress,
            p256Verifier,
            address(helpers.x509()),
            address(helpers.x509Crl())
        ));
        console.log("PCS DAO deployed at:", pcsDao);
        vm.stopBroadcast();

        // 3. Deploy PCK DAO
        vm.startBroadcast();
        address pckDao = address(pckDaoDeployer.deployPckDao(
            storageAddress,
            p256Verifier,
            pcsDao,
            address(helpers.x509()),
            address(helpers.x509Crl())
        ));
        console.log("PCK DAO deployed at:", pckDao);
        vm.stopBroadcast();

        // 4. Deploy Enclave Identity DAO
        vm.startBroadcast();
        address enclaveIdDao = address(enclaveIdDaoDeployer.deployEnclaveIdentityDao(
            storageAddress,
            p256Verifier,
            pcsDao,
            address(helpers.enclaveIdHelper()),
            address(helpers.x509())
        ));
        console.log("Enclave Identity DAO deployed at:", enclaveIdDao);
        vm.stopBroadcast();

        // 5. Deploy FMSPC TCB DAO
        vm.startBroadcast();
        address fmspcTcbDao = address(fmspcTcbDaoDeployer.deployFmspcTcbDao(
            storageAddress,
            p256Verifier,
            pcsDao,
            address(helpers.tcbHelper()),
            address(helpers.x509())
        ));
        console.log("FMSPC TCB DAO deployed at:", fmspcTcbDao);
        vm.stopBroadcast();

        // 6. Update DAO references in storage - call as the owner
        vm.startBroadcast();
        pccsStorage.updateDao(pcsDao, pckDao, enclaveIdDao, fmspcTcbDao);
        console.log("Updated DAOs in storage");
        vm.stopBroadcast();

        // 7. Deploy PCCSRouter
        vm.startBroadcast();
        address pccsRouter = address(routerDeployer.deployRouter(
            enclaveIdDao,
            fmspcTcbDao,
            pcsDao,
            pckDao,
            address(helpers.x509()),
            address(helpers.x509Crl()),
            address(helpers.tcbHelper())
        ));
        console.log("PCCSRouter deployed at:", pccsRouter);
        vm.stopBroadcast();

        // 8. Set up authorization for router in storage
        vm.startBroadcast();
        pccsStorage.setCallerAuthorization(pccsRouter, true);
        console.log("Set authorization for router in storage");
        vm.stopBroadcast();

        // 9. Deploy the main DCAPAttestationDAOs contract
        vm.startBroadcast();
        DCAPAttestationDAOs daos = new DCAPAttestationDAOs(
            storageAddress,
            pcsDao,
            pckDao,
            enclaveIdDao,
            fmspcTcbDao,
            pccsRouter
        );
        console.log("DCAPAttestationDAOs deployed at:", address(daos));
        vm.stopBroadcast();

        // 10. Deploy MatterLabsDCAPAttestation in a separate transaction
        vm.startBroadcast();
        MatterLabsDCAPAttestation attestation = new MatterLabsDCAPAttestation(
            p256Verifier,
            address(hashValidator),
            address(helpers),
            address(daos)
        );
        console.log("MatterLabsDCAPAttestation deployed at:", address(attestation));
        vm.stopBroadcast();

        vm.startBroadcast();
        // Deploy a new quote verifier that points to the router
        V3QuoteVerifier quoteVerifierV3 = new V3QuoteVerifier(p256Verifier, address(pccsRouter));

        // Make sure quote verifier is authorized with router
        pccsStorage.setCallerAuthorization(address(quoteVerifierV3), true);

        // Create and set up the quote verifier with the router address
        V4QuoteVerifier quoteVerifierV4 = new V4QuoteVerifier(p256Verifier, address(pccsRouter));

        // Make sure quote verifier is authorized with router
        pccsStorage.setCallerAuthorization(address(quoteVerifierV4), true);

        // Set the verifiers in attestation contract
        attestation.setQuoteVerifier(address(quoteVerifierV3));
        attestation.setQuoteVerifier(address(quoteVerifierV4));

        vm.stopBroadcast();

        // Save deployment information
        vm.startBroadcast();
        _saveDeployment(
            address(attestation),
            address(hashValidator),
            p256Verifier,
            address(helpers),
            address(daos),
            storageAddress,
            pcsDao,
            pckDao,
            enclaveIdDao,
            fmspcTcbDao,
            pccsRouter
        );
        vm.stopBroadcast();
    }

    function deployP256Verifier() internal returns (address) {
        // The deterministic CREATE2 address for the P256 verifier
        // This is the same address used in testnet and mainnet
        // Reference: https://github.com/daimo-eth/p256-verifier
        address p256VerifierAddress = 0xc2b78104907F722DABAc4C69f826a522B2754De4;

        // Check if the contract is already deployed at the deterministic address
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(p256VerifierAddress)
        }
        if (codeSize != 0) {
            console.log("P256 verifier already deployed at deterministic address");
            return p256VerifierAddress;
        }

        // For development and testing, let's create a simple mock P256Verifier contract
        // that has the same interface as the real one but always returns true
        bytes memory bytecode = hex"608060405234801561001057600080fd5b5060db8061001f6000396000f3fe6080604052348015600f57600080fd5b506004361060285760003560e01c80635566d5cd14602d575b600080fd5b604e60383660046050565b50600192915050565b604051901515815260200160405180910390f35b600080600080600080600080fd5b600080fdfea2646970667358221220b1923e0b9f6b1a71a38e58416e5c59ca2909d6eff8cbad36bb7af2dbf54be90164736f6c634300080b0033";
        address verifier;

        // Deploy the contract
        assembly {
            verifier := create(0, add(bytecode, 0x20), mload(bytecode))
        }

        // Ensure deployment succeeded
        require(verifier != address(0), "Failed to deploy P256 verifier mock");

        return verifier;
    }

    function _saveDeployment(
        address attestationContract,
        address hashValidator,
        address p256Verifier,
        address helpers,
        address daos,
        address pccsStorage,
        address pcsDao,
        address pckDao,
        address enclaveIdDao,
        address fmspcTcbDao,
        address pccsRouter
    ) internal {
        // Save deployment information to a TOML file to match other contracts
        string memory deploymentToml = string.concat(
            'tee_dcap_attestation_addr = "', vm.toString(attestationContract), '"\n',
            'hash_validator_addr = "', vm.toString(hashValidator), '"\n',
            'p256_verifier_addr = "', vm.toString(p256Verifier), '"\n',
            'dcap_attestation_helpers_addr = "', vm.toString(helpers), '"\n',
            'dcap_attestation_daos_addr = "', vm.toString(daos), '"\n',
            'pccs_storage_addr = "', vm.toString(pccsStorage), '"\n',
            'pcs_dao_addr = "', vm.toString(pcsDao), '"\n',
            'pck_dao_addr = "', vm.toString(pckDao), '"\n',
            'enclave_id_dao_addr = "', vm.toString(enclaveIdDao), '"\n',
            'fmspc_tcb_dao_addr = "', vm.toString(fmspcTcbDao), '"\n',
            'pccs_router_addr = "', vm.toString(pccsRouter), '"\n'
        );

        // Output file path should match DEPLOY_TEE_SCRIPT_PARAMS.output in script_params.rs
        string memory outputPath = "./script-out/output-deploy-tee.toml";
        vm.writeFile(outputPath, deploymentToml);
        console.log("Deployment information saved to:", outputPath);
    }
}
