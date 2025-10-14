// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {StateTransitionDeployedAddresses, Utils} from "./Utils.sol";
import {IVerifier, VerifierParams} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {ChainCreationParams, ChainTypeManagerInitializeData, IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {Create2AndTransfer} from "./Create2AndTransfer.sol";
import {Create2FactoryUtils} from "./Create2FactoryUtils.s.sol";
import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";

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
        // TODO IT's never deployed
        address diamondProxy;
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

abstract contract DeployUtils is Create2FactoryUtils {
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

        config.tokens.tokenWethAddress = toml.readAddress("$.tokens.token_weth_address");
    }

    ////////////////////////////// Contract deployment modes /////////////////////////////////

    function deploySimpleContract(
        string memory contractName,
        bool isZKBytecode
    ) internal returns (address contractAddress) {
        contractAddress = deployViaCreate2AndNotify(
            getCreationCode(contractName, false),
            getCreationCalldata(contractName, false),
            contractName,
            isZKBytecode
        );
    }

    function deployWithCreate2AndOwner(
        string memory contractName,
        address owner,
        bool isZKBytecode
    ) internal returns (address contractAddress) {
        contractAddress = deployWithOwnerAndNotify(
            getCreationCode(contractName, false),
            getCreationCalldata(contractName, false),
            owner,
            contractName,
            string.concat(contractName, " Implementation"),
            isZKBytecode
        );
    }

    function deployTuppWithContract(
        string memory contractName,
        bool isZKBytecode
    ) internal virtual returns (address implementation, address proxy);

    function getCreationCode(
        string memory contractName,
        bool isZKBytecode
    ) internal view virtual returns (bytes memory);

    function getCreationCalldata(
        string memory contractName,
        bool isZKBytecode
    ) internal view virtual returns (bytes memory) {
        if (compareStrings(contractName, "ChainRegistrar")) {
            return abi.encode();
        } else if (compareStrings(contractName, "ProxyAdmin")) {
            return abi.encode();

        } else if (compareStrings(contractName, "BridgedStandardERC20")) {
            return abi.encode();
        } else if (compareStrings(contractName, "BridgedTokenBeacon")) {
            return abi.encode(addresses.bridges.bridgedStandardERC20Implementation);
        } else if (compareStrings(contractName, "Bridgehub")) {
            return abi.encode(config.l1ChainId, config.ownerAddress, (config.contracts.maxNumberOfChains));
        } else if (compareStrings(contractName, "MessageRoot")) {
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
            return
                abi.encode(
                addresses.bridgehub.bridgehubProxy,
                config.eraChainId,
                addresses.diamondProxy
            );
        } else if (compareStrings(contractName, "L1AssetRouter")) {
            return
                abi.encode(
                config.tokens.tokenWethAddress,
                addresses.bridgehub.bridgehubProxy,
                addresses.bridges.l1NullifierProxy,
                config.eraChainId,
                addresses.diamondProxy
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

    function getInitializeCalldata(
        string memory contractName,
        bool isZKBytecode
    ) internal virtual returns (bytes memory);

    function test() internal virtual {}
}
