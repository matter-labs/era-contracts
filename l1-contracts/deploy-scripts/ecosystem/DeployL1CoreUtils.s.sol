// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";
import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {Governance} from "contracts/governance/Governance.sol";
import {CTMDeploymentTracker} from "contracts/core/ctm-deployment/CTMDeploymentTracker.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {L1NullifierDev} from "contracts/dev-contracts/L1NullifierDev.sol";
import {L1ERC20Bridge} from "contracts/bridge/L1ERC20Bridge.sol";
import {ChainAdminOwnable} from "contracts/governance/ChainAdminOwnable.sol";
import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";
import {L1ChainAssetHandler} from "contracts/core/chain-asset-handler/L1ChainAssetHandler.sol";
import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {L1AssetTracker} from "contracts/bridge/asset-tracker/L1AssetTracker.sol";
import {ChainRegistrationSender} from "contracts/core/chain-registration/ChainRegistrationSender.sol";
import {ContractsBytecodesLib} from "../utils/bytecode/ContractsBytecodesLib.sol";
import {BridgehubAddresses, BridgesDeployedAddresses, CoreDeployedAddresses} from "../utils/Types.sol";
import {DeployUtils} from "../utils/deploy/DeployUtils.sol";

// solhint-disable-next-line gas-struct-packing
struct Config {
    uint256 l1ChainId;
    address ownerAddress;
    address deployerAddress;
    uint256 eraChainId;
    address eraDiamondProxyAddress;
    bool supportL2LegacySharedBridgeTest;
    ContractsConfig contracts;
    TokensConfig tokens;
}

// solhint-disable-next-line gas-struct-packing
struct ContractsConfig {
    address governanceSecurityCouncilAddress;
    uint256 governanceMinDelay;
    uint256 maxNumberOfChains;
}

struct TokensConfig {
    address tokenWethAddress;
}

contract DeployL1CoreUtils is DeployUtils {
    using stdToml for string;

    Config public config;
    // Note: This variable is populated during deployment by concrete implementations
    CoreDeployedAddresses internal coreAddresses; //slither-disable-line uninitialized-state

    //slither-disable-next-line reentrancy-benign
    function initializeConfig(string memory configPath) public virtual {
        string memory toml = vm.readFile(configPath);

        config.l1ChainId = block.chainid;
        config.deployerAddress = msg.sender;

        // Config file must be parsed key by key, otherwise values returned
        // are parsed alfabetically and not by key.
        // https://book.getfoundry.sh/cheatcodes/parse-toml
        config.eraChainId = toml.readUint("$.era_chain_id");
        config.ownerAddress = toml.readAddress("$.owner_address");
        config.supportL2LegacySharedBridgeTest = toml.readBool("$.support_l2_legacy_shared_bridge_test");

        config.contracts.governanceSecurityCouncilAddress = toml.readAddress(
            "$.contracts.governance_security_council_address"
        );
        config.contracts.governanceMinDelay = toml.readUint("$.contracts.governance_min_delay");
        config.contracts.maxNumberOfChains = toml.readUint("$.contracts.max_number_of_chains");

        (address create2FactoryAddr, bytes32 create2FactorySalt) = getPermanentValues();
        _initCreate2FactoryParams(create2FactoryAddr, create2FactorySalt);
        instantiateCreate2Factory();

        if (vm.keyExistsToml(toml, "$.contracts.era_diamond_proxy_addr")) {
            config.eraDiamondProxyAddress = toml.readAddress("$.contracts.era_diamond_proxy_addr");
        }
        config.tokens.tokenWethAddress = toml.readAddress("$.tokens.token_weth_address");
    }

    ////////////////////////////// Contract deployment modes /////////////////////////////////

    function getCreationCalldata(
        string memory contractName,
        bool isZKBytecode
    ) internal view virtual override returns (bytes memory) {
        if (compareStrings(contractName, "ChainRegistrar")) {
            return abi.encode();
        } else if (compareStrings(contractName, "ProxyAdmin")) {
            return abi.encode();
        } else if (compareStrings(contractName, "ChainRegistrationSender")) {
            return abi.encode(coreAddresses.bridgehub.proxies.bridgehub);
        } else if (compareStrings(contractName, "InteropCenter")) {
            return abi.encode(coreAddresses.bridgehub.proxies.bridgehub, config.l1ChainId, config.ownerAddress);
        } else if (compareStrings(contractName, "BridgedStandardERC20")) {
            return abi.encode();
        } else if (compareStrings(contractName, "BridgedTokenBeacon")) {
            return abi.encode(coreAddresses.bridges.bridgedStandardERC20Implementation);
        } else if (compareStrings(contractName, "L1Bridgehub")) {
            return abi.encode(config.l1ChainId, config.ownerAddress, (config.contracts.maxNumberOfChains));
        } else if (compareStrings(contractName, "L1MessageRoot")) {
            return abi.encode(coreAddresses.bridgehub.proxies.bridgehub, config.l1ChainId);
        } else if (compareStrings(contractName, "CTMDeploymentTracker")) {
            return abi.encode(coreAddresses.bridgehub.proxies.bridgehub, coreAddresses.bridges.proxies.l1AssetRouter);
        } else if (compareStrings(contractName, "ChainAssetHandler")) {
            return
                abi.encode(
                    config.l1ChainId,
                    config.ownerAddress,
                    coreAddresses.bridgehub.proxies.bridgehub,
                    coreAddresses.bridges.proxies.l1AssetRouter,
                    coreAddresses.bridgehub.proxies.messageRoot
                );
        } else if (compareStrings(contractName, "L1Nullifier")) {
            if (config.supportL2LegacySharedBridgeTest) {
                return
                    abi.encode(
                        coreAddresses.bridgehub.proxies.bridgehub,
                        coreAddresses.bridgehub.proxies.messageRoot,
                        config.eraChainId,
                        config.eraDiamondProxyAddress
                    );
            } else {
                return
                    abi.encode(
                        coreAddresses.bridgehub.proxies.bridgehub,
                        coreAddresses.bridgehub.proxies.messageRoot,
                        config.eraChainId,
                        config.eraDiamondProxyAddress
                    );
            }
        } else if (compareStrings(contractName, "L1ChainAssetHandler")) {
            return
                abi.encode(
                    config.ownerAddress,
                    coreAddresses.bridgehub.proxies.bridgehub,
                    coreAddresses.bridges.proxies.l1AssetRouter,
                    coreAddresses.bridgehub.proxies.messageRoot,
                    coreAddresses.bridgehub.proxies.assetTracker,
                    coreAddresses.bridges.proxies.l1Nullifier
                );
        } else if (compareStrings(contractName, "L1AssetRouter")) {
            return
                abi.encode(
                    config.tokens.tokenWethAddress,
                    coreAddresses.bridgehub.proxies.bridgehub,
                    coreAddresses.bridges.proxies.l1Nullifier,
                    config.eraChainId,
                    config.eraDiamondProxyAddress
                );
        } else if (compareStrings(contractName, "L1ERC20Bridge")) {
            return
                abi.encode(
                    coreAddresses.bridges.proxies.l1Nullifier,
                    coreAddresses.bridges.proxies.l1AssetRouter,
                    coreAddresses.bridges.proxies.l1NativeTokenVault,
                    config.eraChainId
                );
        } else if (compareStrings(contractName, "L1NativeTokenVault")) {
            return
                abi.encode(
                    config.tokens.tokenWethAddress,
                    coreAddresses.bridges.proxies.l1AssetRouter,
                    coreAddresses.bridges.proxies.l1Nullifier
                );
        } else if (compareStrings(contractName, "Governance")) {
            return
                abi.encode(
                    config.ownerAddress,
                    config.contracts.governanceSecurityCouncilAddress,
                    config.contracts.governanceMinDelay
                );
        } else if (compareStrings(contractName, "ChainAdminOwnable")) {
            return abi.encode(config.ownerAddress, address(0));
        } else if (compareStrings(contractName, "L1AssetTracker")) {
            return
                abi.encode(
                    coreAddresses.bridgehub.proxies.bridgehub,
                    coreAddresses.bridges.proxies.l1NativeTokenVault,
                    coreAddresses.bridgehub.proxies.messageRoot
                );
        } else if (compareStrings(contractName, "ChainAdmin")) {
            address[] memory restrictions = new address[](1);
            restrictions[0] = coreAddresses.shared.accessControlRestrictionAddress;
            return abi.encode(restrictions);
        } else {
            revert(string.concat("Contract ", contractName, " creation calldata not set"));
        }
    }

    function transparentProxyAdmin() internal virtual override returns (address) {
        return coreAddresses.shared.transparentProxyAdmin;
    }

    function getCreationCode(
        string memory contractName,
        bool isZKBytecode
    ) internal view virtual override returns (bytes memory) {
        if (!isZKBytecode) {
            if (compareStrings(contractName, "L1Bridgehub")) {
                return type(L1Bridgehub).creationCode;
            } else if (compareStrings(contractName, "L1ChainAssetHandler")) {
                return type(L1ChainAssetHandler).creationCode;
            } else if (compareStrings(contractName, "ChainRegistrationSender")) {
                return type(ChainRegistrationSender).creationCode;
            } else if (compareStrings(contractName, "L1MessageRoot")) {
                return type(L1MessageRoot).creationCode;
            } else if (compareStrings(contractName, "CTMDeploymentTracker")) {
                return type(CTMDeploymentTracker).creationCode;
            } else if (compareStrings(contractName, "L1Nullifier")) {
                if (config.supportL2LegacySharedBridgeTest) {
                    return type(L1NullifierDev).creationCode;
                } else {
                    return type(L1Nullifier).creationCode;
                }
            } else if (compareStrings(contractName, "L1AssetRouter")) {
                return type(L1AssetRouter).creationCode;
            } else if (compareStrings(contractName, "L1AssetTracker")) {
                return type(L1AssetTracker).creationCode;
            } else if (compareStrings(contractName, "L1ERC20Bridge")) {
                return type(L1ERC20Bridge).creationCode;
            } else if (compareStrings(contractName, "L1NativeTokenVault")) {
                return type(L1NativeTokenVault).creationCode;
            } else if (compareStrings(contractName, "BridgedStandardERC20")) {
                return type(BridgedStandardERC20).creationCode;
            } else if (compareStrings(contractName, "BridgedTokenBeacon")) {
                return type(UpgradeableBeacon).creationCode;
            } else if (compareStrings(contractName, "Governance")) {
                return type(Governance).creationCode;
            } else if (compareStrings(contractName, "ChainAdminOwnable")) {
                return type(ChainAdminOwnable).creationCode;
            } else if (compareStrings(contractName, "ChainAdmin")) {
                return type(ChainAdmin).creationCode;
            } else if (compareStrings(contractName, "ProxyAdmin")) {
                return type(ProxyAdmin).creationCode;
            }
        }
        return ContractsBytecodesLib.getCreationCode(contractName, isZKBytecode);
    }

    function getInitializeCalldata(
        string memory contractName,
        bool isZKBytecode
    ) internal virtual override returns (bytes memory) {
        if (!isZKBytecode) {
            if (compareStrings(contractName, "L1Bridgehub")) {
                return abi.encodeCall(L1Bridgehub.initialize, (config.deployerAddress));
            } else if (compareStrings(contractName, "L1MessageRoot")) {
                return abi.encodeCall(L1MessageRoot.initialize, ());
            } else if (compareStrings(contractName, "ChainRegistrationSender")) {
                return abi.encodeCall(ChainRegistrationSender.initialize, (config.deployerAddress));
            } else if (compareStrings(contractName, "L1AssetTracker")) {
                return abi.encodeCall(L1AssetTracker.initialize, (config.deployerAddress));
            } else if (compareStrings(contractName, "L1ChainAssetHandler")) {
                return abi.encodeCall(L1ChainAssetHandler.initialize, (config.deployerAddress));
            } else if (compareStrings(contractName, "CTMDeploymentTracker")) {
                return abi.encodeCall(CTMDeploymentTracker.initialize, (config.deployerAddress));
            } else if (compareStrings(contractName, "L1Nullifier")) {
                return abi.encodeCall(L1Nullifier.initialize, (config.deployerAddress, 1, 1, 1, 0));
            } else if (compareStrings(contractName, "L1AssetRouter")) {
                return abi.encodeCall(L1AssetRouter.initialize, (config.deployerAddress));
            } else if (compareStrings(contractName, "L1ERC20Bridge")) {
                return abi.encodeCall(L1ERC20Bridge.initialize, ());
            } else if (compareStrings(contractName, "L1NativeTokenVault")) {
                return
                    abi.encodeCall(
                        L1NativeTokenVault.initialize,
                        (config.deployerAddress, coreAddresses.bridges.bridgedTokenBeacon)
                    );
            } else {
                revert(string.concat("Contract ", contractName, " initialize calldata not set"));
            }
        } else {
            revert(string.concat("Contract ", contractName, " ZK initialize calldata not set"));
        }
    }

    function test() internal virtual {}
}
