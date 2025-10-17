// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {L1Bridgehub} from "contracts/bridgehub/L1Bridgehub.sol";
import {DeployUtils} from "./DeployUtils.sol";
import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {Governance} from "contracts/governance/Governance.sol";
import {CTMDeploymentTracker} from "contracts/bridgehub/CTMDeploymentTracker.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {L1NullifierDev} from "contracts/dev-contracts/L1NullifierDev.sol";
import {L1ERC20Bridge} from "contracts/bridge/L1ERC20Bridge.sol";
import {ChainAdminOwnable} from "contracts/governance/ChainAdminOwnable.sol";
import {L1MessageRoot} from "contracts/bridgehub/L1MessageRoot.sol";
import {L1ChainAssetHandler} from "contracts/bridgehub/L1ChainAssetHandler.sol";
import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ContractsBytecodesLib} from "./ContractsBytecodesLib.sol";

// solhint-disable-next-line gas-struct-packing
struct DeployedAddresses {
    BridgehubDeployedAddresses bridgehub;
    BridgesDeployedAddresses bridges;
    L1NativeTokenVaultAddresses vaults;
    address transparentProxyAdmin;
    address governance;
    address chainAdmin;
    address accessControlRestrictionAddress;
    address create2Factory;
}

// solhint-disable-next-line gas-struct-packing
struct L1NativeTokenVaultAddresses {
    address l1NativeTokenVaultImplementation;
    address l1NativeTokenVaultProxy;
}

// solhint-disable-next-line gas-struct-packing
struct BridgehubDeployedAddresses {
    address bridgehubImplementation;
    address bridgehubProxy;
    address ctmDeploymentTrackerImplementation;
    address ctmDeploymentTrackerProxy;
    address messageRootImplementation;
    address messageRootProxy;
    address chainAssetHandlerImplementation;
    address chainAssetHandlerProxy;
}

// solhint-disable-next-line gas-struct-packing
struct BridgesDeployedAddresses {
    address erc20BridgeImplementation;
    address erc20BridgeProxy;
    address l1AssetRouterImplementation;
    address l1AssetRouterProxy;
    address l1NullifierImplementation;
    address l1NullifierProxy;
    address bridgedStandardERC20Implementation;
    address bridgedTokenBeacon;
}

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

// solhint-disable-next-line gas-struct-packing
struct GeneratedData {
    bytes forceDeploymentsData;
}

abstract contract DeployL1CoreUtils is DeployUtils {
    using stdToml for string;

    Config public config;
    GeneratedData internal generatedData;
    DeployedAddresses internal addresses;

    function initializeConfig(string memory configPath) internal virtual {
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

        bytes32 create2FactorySalt = toml.readBytes32("$.contracts.create2_factory_salt");
        address create2FactoryAddr;
        if (vm.keyExistsToml(toml, "$.contracts.create2_factory_addr")) {
            create2FactoryAddr = toml.readAddress("$.contracts.create2_factory_addr");
        }
        _initCreate2FactoryParams(create2FactoryAddr, create2FactorySalt);

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
        } else if (compareStrings(contractName, "BridgedStandardERC20")) {
            return abi.encode();
        } else if (compareStrings(contractName, "BridgedTokenBeacon")) {
            return abi.encode(addresses.bridges.bridgedStandardERC20Implementation);
        } else if (compareStrings(contractName, "L1Bridgehub")) {
            return abi.encode(config.l1ChainId, config.ownerAddress, (config.contracts.maxNumberOfChains));
        } else if (compareStrings(contractName, "L1MessageRoot")) {
            return abi.encode(addresses.bridgehub.bridgehubProxy, config.l1ChainId);
        } else if (compareStrings(contractName, "CTMDeploymentTracker")) {
            return abi.encode(addresses.bridgehub.bridgehubProxy, addresses.bridges.l1AssetRouterProxy);
        } else if (compareStrings(contractName, "ChainAssetHandler")) {
            return
                abi.encode(
                    config.l1ChainId,
                    config.ownerAddress,
                    addresses.bridgehub.bridgehubProxy,
                    addresses.bridges.l1AssetRouterProxy,
                    addresses.bridgehub.messageRootProxy
                );
        } else if (compareStrings(contractName, "L1Nullifier")) {
            return abi.encode(addresses.bridgehub.bridgehubProxy, config.eraChainId, config.eraDiamondProxyAddress);
        } else if (compareStrings(contractName, "L1ChainAssetHandler")) {
            return
                abi.encode(
                    config.ownerAddress,
                    addresses.bridgehub.bridgehubProxy,
                    addresses.bridges.l1AssetRouterProxy,
                    addresses.bridgehub.messageRootProxy
                );
        } else if (compareStrings(contractName, "L1AssetRouter")) {
            return
                abi.encode(
                    config.tokens.tokenWethAddress,
                    addresses.bridgehub.bridgehubProxy,
                    addresses.bridges.l1NullifierProxy,
                    config.eraChainId,
                    config.eraDiamondProxyAddress
                );
        } else if (compareStrings(contractName, "L1ERC20Bridge")) {
            return
                abi.encode(
                    addresses.bridges.l1NullifierProxy,
                    addresses.bridges.l1AssetRouterProxy,
                    addresses.vaults.l1NativeTokenVaultProxy,
                    config.eraChainId
                );
        } else if (compareStrings(contractName, "L1NativeTokenVault")) {
            return
                abi.encode(
                    config.tokens.tokenWethAddress,
                    addresses.bridges.l1AssetRouterProxy,
                    addresses.bridges.l1NullifierProxy
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
        } else if (compareStrings(contractName, "ChainAdmin")) {
            address[] memory restrictions = new address[](1);
            restrictions[0] = addresses.accessControlRestrictionAddress;
            return abi.encode(restrictions);
        } else {
            revert(string.concat("Contract ", contractName, " creation calldata not set"));
        }
    }

    function transparentProxyAdmin() internal virtual override returns (address) {
        return addresses.transparentProxyAdmin;
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
                        (config.ownerAddress, addresses.bridges.bridgedTokenBeacon)
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
