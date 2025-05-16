// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable gas-custom-errors, reason-string

import {Vm} from "forge-std/Vm.sol";
import {console2 as console} from "forge-std/Script.sol";

import {IAccessControlDefaultAdminRules} from "@openzeppelin/contracts-v4/access/IAccessControlDefaultAdminRules.sol";

import {L2TransactionRequestDirect, L2TransactionRequestTwoBridgesOuter, IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {IGovernance} from "contracts/governance/IGovernance.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {IOwnable} from "./interfaces/IOwnable.sol";
import {Call} from "contracts/governance/Common.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";
import {L2_DEPLOYER_SYSTEM_CONTRACT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {L2ContractHelper} from "contracts/common/libraries/L2ContractHelper.sol";
import {IChainAdmin} from "contracts/governance/IChainAdmin.sol";
import {EIP712Utils} from "./EIP712Utils.sol";
import {IProtocolUpgradeHandler} from "./interfaces/IProtocolUpgradeHandler.sol";
import {IEmergencyUpgrageBoard} from "./interfaces/IEmergencyUpgrageBoard.sol";
import {ISecurityCouncil} from "./interfaces/ISecurityCouncil.sol";
import {IMultisig} from "./interfaces/IMultisig.sol";
import {ISafe} from "./interfaces/ISafe.sol";
import {ChainAdminOwnable} from "contracts/governance/ChainAdminOwnable.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";

/// @dev EIP-712 TypeHash for the emergency protocol upgrade execution approved by the guardians.
bytes32 constant EXECUTE_EMERGENCY_UPGRADE_GUARDIANS_TYPEHASH = keccak256(
    "ExecuteEmergencyUpgradeGuardians(bytes32 id)"
);

/// @dev EIP-712 TypeHash for the emergency protocol upgrade execution approved by the Security Council.
bytes32 constant EXECUTE_EMERGENCY_UPGRADE_SECURITY_COUNCIL_TYPEHASH = keccak256(
    "ExecuteEmergencyUpgradeSecurityCouncil(bytes32 id)"
);

/// @dev EIP-712 TypeHash for the emergency protocol upgrade execution approved by the ZK Foundation.
bytes32 constant EXECUTE_EMERGENCY_UPGRADE_ZK_FOUNDATION_TYPEHASH = keccak256(
    "ExecuteEmergencyUpgradeZKFoundation(bytes32 id)"
);

/// @dev EIP-712 TypeHash for protocol upgrades approval by the Security Council.
bytes32 constant APPROVE_UPGRADE_SECURITY_COUNCIL_TYPEHASH = keccak256("ApproveUpgradeSecurityCouncil(bytes32 id)");

/// @dev The offset from which the built-in, but user space contracts are located.
uint160 constant USER_CONTRACTS_OFFSET = 0x10000; // 2^16

// address constant
address constant L2_BRIDGEHUB_ADDRESS = address(USER_CONTRACTS_OFFSET + 0x02);
address constant L2_ASSET_ROUTER_ADDRESS = address(USER_CONTRACTS_OFFSET + 0x03);
address constant L2_NATIVE_TOKEN_VAULT_ADDRESS = address(USER_CONTRACTS_OFFSET + 0x04);
address constant L2_MESSAGE_ROOT_ADDRESS = address(USER_CONTRACTS_OFFSET + 0x05);
address constant L2_WETH_IMPL_ADDRESS = address(USER_CONTRACTS_OFFSET + 0x07);

/// @dev the address of the Gateway-specific upgrader contract
address constant L2_GATEWAY_SPECIFIC_UPGRADER = address(USER_CONTRACTS_OFFSET + 0x08);

address constant L2_CREATE2_FACTORY_ADDRESS = address(USER_CONTRACTS_OFFSET);

uint256 constant SECURITY_COUNCIL_SIZE = 12;

// solhint-disable-next-line gas-struct-packing
struct StateTransitionDeployedAddresses {
    address chainTypeManagerProxy;
    address chainTypeManagerImplementation;
    address verifier;
    address verifierFflonk;
    address verifierPlonk;
    address adminFacet;
    address mailboxFacet;
    address executorFacet;
    address gettersFacet;
    address diamondInit;
    address genesisUpgrade;
    address defaultUpgrade;
    address validatorTimelock;
    address diamondProxy;
    address bytecodesSupplier;
    address serverNotifierProxy;
    address serverNotifierImplementation;
    bool isOnGateway;
}

/// @dev We need to use a struct instead of list of params to prevent stack too deep error
struct PrepareL1L2TransactionParams {
    uint256 l1GasPrice;
    bytes l2Calldata;
    uint256 l2GasLimit;
    uint256 l2Value;
    bytes[] factoryDeps;
    address dstAddress;
    uint256 chainId;
    address bridgehubAddress;
    address l1SharedBridgeProxy;
    address refundRecipient;
}

struct SelectorToFacet {
    address facetAddress;
    uint16 selectorPosition;
    bool isFreezable;
}

struct FacetToSelectors {
    bytes4[] selectors;
    uint16 facetPosition;
}

struct FacetCut {
    address facet;
    Action action;
    bool isFreezable;
    bytes4[] selectors;
}

enum Action {
    Add,
    Replace,
    Remove
}

struct ChainInfoFromBridgehub {
    address diamondProxy;
    address admin;
    address ctm;
    address serverNotifier;
    address l1AssetRouterProxy;
}

address constant ADDRESS_ONE = 0x0000000000000000000000000000000000000001;

library Utils {
    // Cheatcodes address, 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D.
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    Vm internal constant vm = Vm(VM_ADDRESS);
    // Create2Factory deterministic bytecode.
    // https://github.com/Arachnid/deterministic-deployment-proxy
    bytes internal constant CREATE2_FACTORY_BYTECODE =
        hex"604580600e600039806000f350fe7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    uint256 internal constant MAX_PRIORITY_TX_GAS = 72000000;

    /**
     * @dev Get all selectors from the bytecode.
     *
     * Selectors are extracted by calling `cast selectors <bytecode>` from foundry.
     * Then, the result is parsed to extract the selectors, removing
     * the `getName()` selector if existing.
     */
    function getAllSelectors(bytes memory bytecode) internal returns (bytes4[] memory) {
        string[] memory input = new string[](3);
        input[0] = "cast";
        input[1] = "selectors";
        input[2] = vm.toString(bytecode);
        bytes memory result = vm.ffi(input);
        string memory stringResult = string(abi.encodePacked(result));

        // Extract selectors from the result
        string[] memory parts = vm.split(stringResult, "\n");
        uint256 partsLength = parts.length;
        bytes4[] memory selectors = new bytes4[](partsLength);
        for (uint256 i = 0; i < partsLength; ++i) {
            bytes memory part = bytes(parts[i]);
            bytes memory extractedSelector = new bytes(10);
            // Selector length 10 is 0x + 4 bytes
            for (uint256 j = 0; j < 10; ++j) {
                extractedSelector[j] = part[j];
            }
            bytes4 selector = bytes4(vm.parseBytes(string(extractedSelector)));
            selectors[i] = selector;
        }

        // Remove `getName()` selector if existing
        bool hasGetName = false;
        uint256 selectorsLength = selectors.length;
        for (uint256 i = 0; i < selectorsLength; ++i) {
            if (selectors[i] == bytes4(keccak256("getName()"))) {
                selectors[i] = selectors[selectors.length - 1];
                hasGetName = true;
                break;
            }
        }
        if (hasGetName) {
            bytes4[] memory newSelectors = new bytes4[](selectorsLength - 1);
            for (uint256 i = 0; i < selectorsLength - 1; ++i) {
                newSelectors[i] = selectors[i];
            }
            return newSelectors;
        }

        return selectors;
    }

    function getAllSelectorsForFacet(string memory facetName) internal returns (bytes4[] memory) {
        // TODO(EVM-746): use forge to read the bytecode
        string memory path = string.concat("/../l1-contracts/out/", facetName, ".sol/", facetName, "Facet.json");
        bytes memory bytecode = readFoundryDeployedBytecode(path);
        return getAllSelectors(bytecode);
    }

    /**
     * @dev Extract an address from bytes.
     */
    function bytesToAddress(bytes memory bys) internal pure returns (address addr) {
        assembly {
            addr := mload(add(bys, 20))
        }
    }

    /**
     * @dev Extract a uint256 from bytes.
     */
    function bytesToUint256(bytes memory bys) internal pure returns (uint256 value) {
        // Add left padding to 32 bytes if needed
        uint256 bysLength = bys.length;
        if (bysLength < 32) {
            bytes memory padded = new bytes(32);
            for (uint256 i = 0; i < bysLength; ++i) {
                padded[i + 32 - bysLength] = bys[i];
            }
            bys = padded;
        }

        assembly {
            value := mload(add(bys, 0x20))
        }
    }

    /**
     * @dev Returns the bytecode hash of the batch bootloader.
     */
    function getBatchBootloaderBytecodeHash() internal view returns (bytes memory) {
        return
            readZKFoundryBytecodeSystemContracts(
                "proved_batch.yul/contracts-preprocessed/bootloader",
                "proved_batch.yul"
            );
    }

    /**
     * @dev Returns the bytecode hash of the EVM emulator.
     */
    function getEvmEmulatorBytecodeHash() internal view returns (bytes memory) {
        return readZKFoundryBytecodeSystemContracts("EvmEmulator.yul/contracts-preprocessed", "EvmEmulator.yul");
    }

    /**
     * @dev Read hardhat bytecodes
     */
    function readHardhatBytecode(string memory artifactPath) internal view returns (bytes memory) {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, artifactPath);
        string memory json = vm.readFile(path);
        bytes memory bytecode = vm.parseJsonBytes(json, ".bytecode");
        return bytecode;
    }

    /**
     * @dev Returns the bytecode of a given system contract.
     */
    function readSystemContractsBytecode(string memory filename) internal view returns (bytes memory) {
        return readZKFoundryBytecodeSystemContracts(string.concat(filename, ".sol"), filename);
    }

    /**
     * @dev Returns the bytecode of a given system contract in yul.
     */
    function readSystemContractsYulBytecode(string memory filename) internal view returns (bytes memory) {
        string memory path = string.concat(
            "/../system-contracts/zkout/",
            filename,
            ".yul/contracts-preprocessed/",
            filename,
            ".yul.json"
        );

        return readFoundryBytecode(path);
    }

    /**
     * @dev Returns the bytecode of a given precompile system contract.
     */
    function readPrecompileBytecode(string memory filename) internal view returns (bytes memory) {
        string memory path = string.concat(
            "/../system-contracts/zkout/",
            filename,
            ".yul/contracts-preprocessed/precompiles/",
            filename,
            ".yul.json"
        );

        return readFoundryBytecode(path);
    }

    /**
     * @dev Deploy a Create2Factory contract.
     */
    function deployCreate2Factory() internal returns (address) {
        address child;
        bytes memory bytecode = CREATE2_FACTORY_BYTECODE;
        vm.startBroadcast();
        assembly {
            child := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        vm.stopBroadcast();
        require(child != address(0), "Failed to deploy create2factory");
        require(child.code.length > 0, "Failed to deploy create2factory");
        return child;
    }

    /**
     * @dev Deploys contract using CREATE2.
     */
    function deployViaCreate2(bytes memory _bytecode, bytes32 _salt, address _factory) internal returns (address) {
        if (_bytecode.length == 0) {
            revert("Bytecode is not set");
        }
        address contractAddress = vm.computeCreate2Address(_salt, keccak256(_bytecode), _factory);
        if (contractAddress.code.length != 0) {
            return contractAddress;
        }

        vm.broadcast();
        (bool success, bytes memory data) = _factory.call(abi.encodePacked(_salt, _bytecode));
        contractAddress = bytesToAddress(data);

        if (!success || contractAddress == address(0) || contractAddress.code.length == 0) {
            revert("Failed to deploy contract via create2");
        }

        return contractAddress;
    }

    /**
     * @dev Deploy l2 contracts through l1
     */
    function deployThroughL1(
        bytes memory bytecode,
        bytes memory constructorargs,
        bytes32 create2salt,
        uint256 l2GasLimit,
        bytes[] memory factoryDeps,
        uint256 chainId,
        address bridgehubAddress,
        address l1SharedBridgeProxy
    ) internal returns (address) {
        (bytes32 bytecodeHash, bytes memory deployData) = getDeploymentCalldata(create2salt, bytecode, constructorargs);

        address contractAddress = L2ContractHelper.computeCreate2Address(
            msg.sender,
            create2salt,
            bytecodeHash,
            keccak256(constructorargs)
        );

        bytes[] memory _factoryDeps = appendArray(factoryDeps, bytecode);

        runL1L2Transaction({
            l2Calldata: deployData,
            l2GasLimit: l2GasLimit,
            l2Value: 0,
            factoryDeps: _factoryDeps,
            dstAddress: L2_DEPLOYER_SYSTEM_CONTRACT_ADDR,
            chainId: chainId,
            bridgehubAddress: bridgehubAddress,
            l1SharedBridgeProxy: l1SharedBridgeProxy,
            refundRecipient: msg.sender
        });
        return contractAddress;
    }

    function getL2AddressViaCreate2Factory(
        bytes32 create2Salt,
        bytes32 bytecodeHash,
        bytes memory constructorArgs
    ) internal view returns (address) {
        return
            L2ContractHelper.computeCreate2Address(
                L2_CREATE2_FACTORY_ADDRESS,
                create2Salt,
                bytecodeHash,
                keccak256(constructorArgs)
            );
    }

    function getDeploymentCalldata(
        bytes32 create2Salt,
        bytes memory bytecode,
        bytes memory constructorArgs
    ) internal view returns (bytes32 bytecodeHash, bytes memory data) {
        bytecodeHash = L2ContractHelper.hashL2Bytecode(bytecode);

        data = abi.encodeWithSignature("create2(bytes32,bytes32,bytes)", create2Salt, bytecodeHash, constructorArgs);
    }

    function appendArray(bytes[] memory array, bytes memory element) internal pure returns (bytes[] memory) {
        uint256 arrayLength = array.length;
        bytes[] memory newArray = new bytes[](arrayLength + 1);
        for (uint256 i = 0; i < arrayLength; ++i) {
            newArray[i] = array[i];
        }
        newArray[arrayLength] = element;
        return newArray;
    }

    /**
     * @dev Deploy l2 contracts through l1, while using built-in L2 Create2Factory contract.
     */
    function deployThroughL1Deterministic(
        bytes memory bytecode,
        bytes memory constructorargs,
        bytes32 create2salt,
        uint256 l2GasLimit,
        bytes[] memory factoryDeps,
        uint256 chainId,
        address bridgehubAddress,
        address l1SharedBridgeProxy
    ) internal returns (address) {
        (bytes32 bytecodeHash, bytes memory deployData) = getDeploymentCalldata(create2salt, bytecode, constructorargs);

        address contractAddress = getL2AddressViaCreate2Factory(create2salt, bytecodeHash, constructorargs);

        bytes[] memory _factoryDeps = appendArray(factoryDeps, bytecode);

        runL1L2Transaction({
            l2Calldata: deployData,
            l2GasLimit: l2GasLimit,
            l2Value: 0,
            factoryDeps: _factoryDeps,
            dstAddress: L2_CREATE2_FACTORY_ADDRESS,
            chainId: chainId,
            bridgehubAddress: bridgehubAddress,
            l1SharedBridgeProxy: l1SharedBridgeProxy,
            refundRecipient: msg.sender
        });
        return contractAddress;
    }

    function prepareL1L2Transaction(
        PrepareL1L2TransactionParams memory params
    )
        internal
        view
        returns (L2TransactionRequestDirect memory l2TransactionRequestDirect, uint256 requiredValueToDeploy)
    {
        IBridgehub bridgehub = IBridgehub(params.bridgehubAddress);

        requiredValueToDeploy =
            bridgehub.l2TransactionBaseCost(
                params.chainId,
                params.l1GasPrice,
                params.l2GasLimit,
                REQUIRED_L2_GAS_PRICE_PER_PUBDATA
            ) *
            2 +
            params.l2Value;

        l2TransactionRequestDirect = L2TransactionRequestDirect({
            chainId: params.chainId,
            mintValue: requiredValueToDeploy,
            l2Contract: params.dstAddress,
            l2Value: params.l2Value,
            l2Calldata: params.l2Calldata,
            l2GasLimit: params.l2GasLimit,
            l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            factoryDeps: params.factoryDeps,
            refundRecipient: params.refundRecipient
        });
    }

    function prepareL1L2TransactionTwoBridges(
        uint256 l1GasPrice,
        uint256 l2GasLimit,
        uint256 chainId,
        address bridgehubAddress,
        address secondBridgeAddress,
        uint256 secondBridgeValue,
        bytes memory secondBridgeCalldata,
        address refundRecipient
    )
        internal
        view
        returns (L2TransactionRequestTwoBridgesOuter memory l2TransactionRequest, uint256 requiredValueToDeploy)
    {
        IBridgehub bridgehub = IBridgehub(bridgehubAddress);

        requiredValueToDeploy =
            bridgehub.l2TransactionBaseCost(chainId, l1GasPrice, l2GasLimit, REQUIRED_L2_GAS_PRICE_PER_PUBDATA) *
            2;

        l2TransactionRequest = L2TransactionRequestTwoBridgesOuter({
            chainId: chainId,
            mintValue: requiredValueToDeploy,
            l2Value: 0,
            l2GasLimit: l2GasLimit,
            l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            refundRecipient: refundRecipient,
            secondBridgeAddress: secondBridgeAddress,
            secondBridgeValue: secondBridgeValue,
            secondBridgeCalldata: secondBridgeCalldata
        });
    }

    /**
     * @dev Run the l2 l1 transaction
     */
    function runL1L2Transaction(
        bytes memory l2Calldata,
        uint256 l2GasLimit,
        uint256 l2Value,
        bytes[] memory factoryDeps,
        address dstAddress,
        uint256 chainId,
        address bridgehubAddress,
        address l1SharedBridgeProxy,
        address refundRecipient
    ) internal {
        IBridgehub bridgehub = IBridgehub(bridgehubAddress);
        (
            L2TransactionRequestDirect memory l2TransactionRequestDirect,
            uint256 requiredValueToDeploy
        ) = prepareL1L2Transaction(
                PrepareL1L2TransactionParams({
                    l1GasPrice: bytesToUint256(vm.rpc("eth_gasPrice", "[]")),
                    l2Calldata: l2Calldata,
                    l2GasLimit: l2GasLimit,
                    l2Value: l2Value,
                    factoryDeps: factoryDeps,
                    dstAddress: dstAddress,
                    chainId: chainId,
                    bridgehubAddress: bridgehubAddress,
                    l1SharedBridgeProxy: l1SharedBridgeProxy,
                    refundRecipient: refundRecipient
                })
            );

        address baseTokenAddress = bridgehub.baseToken(chainId);
        if (ADDRESS_ONE != baseTokenAddress) {
            IERC20 baseToken = IERC20(baseTokenAddress);
            vm.broadcast();
            baseToken.approve(l1SharedBridgeProxy, requiredValueToDeploy);
            requiredValueToDeploy = 0;
        }

        vm.broadcast();
        bridgehub.requestL2TransactionDirect{value: requiredValueToDeploy}(l2TransactionRequestDirect);
    }

    function prepareGovernanceL1L2DirectTransaction(
        uint256 l1GasPrice,
        bytes memory l2Calldata,
        uint256 l2GasLimit,
        bytes[] memory factoryDeps,
        address dstAddress,
        uint256 chainId,
        address bridgehubAddress,
        address l1SharedBridgeProxy,
        address refundRecipient
    ) internal view returns (Call[] memory calls) {
        (
            L2TransactionRequestDirect memory l2TransactionRequestDirect,
            uint256 requiredValueToDeploy
        ) = prepareL1L2Transaction(
                PrepareL1L2TransactionParams({
                    l1GasPrice: l1GasPrice,
                    l2Calldata: l2Calldata,
                    l2GasLimit: l2GasLimit,
                    l2Value: 0,
                    factoryDeps: factoryDeps,
                    dstAddress: dstAddress,
                    chainId: chainId,
                    bridgehubAddress: bridgehubAddress,
                    l1SharedBridgeProxy: l1SharedBridgeProxy,
                    refundRecipient: refundRecipient
                })
            );

        (uint256 ethAmountToPass, Call[] memory newCalls) = prepareApproveBaseTokenGovernanceCalls(
            IBridgehub(bridgehubAddress),
            l1SharedBridgeProxy,
            chainId,
            requiredValueToDeploy
        );

        calls = mergeCalls(calls, newCalls);

        bytes memory l2TransactionRequestDirectCalldata = abi.encodeCall(
            IBridgehub.requestL2TransactionDirect,
            (l2TransactionRequestDirect)
        );

        calls = appendCall(
            calls,
            Call({target: bridgehubAddress, value: ethAmountToPass, data: l2TransactionRequestDirectCalldata})
        );
    }

    function prepareGovernanceL1L2TwoBridgesTransaction(
        uint256 l1GasPrice,
        uint256 l2GasLimit,
        uint256 chainId,
        address bridgehubAddress,
        address l1SharedBridgeProxy,
        address secondBridgeAddress,
        uint256 secondBridgeValue,
        bytes memory secondBridgeCalldata,
        address refundRecipient
    ) internal view returns (Call[] memory calls) {
        (
            L2TransactionRequestTwoBridgesOuter memory l2TransactionRequest,
            uint256 requiredValueToDeploy
        ) = prepareL1L2TransactionTwoBridges(
                l1GasPrice,
                l2GasLimit,
                chainId,
                bridgehubAddress,
                secondBridgeAddress,
                secondBridgeValue,
                secondBridgeCalldata,
                refundRecipient
            );

        (uint256 ethAmountToPass, Call[] memory newCalls) = prepareApproveBaseTokenGovernanceCalls(
            IBridgehub(bridgehubAddress),
            l1SharedBridgeProxy,
            chainId,
            requiredValueToDeploy
        );

        calls = mergeCalls(calls, newCalls);

        bytes memory l2TransactionRequestCalldata = abi.encodeCall(
            IBridgehub.requestL2TransactionTwoBridges,
            (l2TransactionRequest)
        );

        calls = appendCall(
            calls,
            Call({target: bridgehubAddress, value: ethAmountToPass, data: l2TransactionRequestCalldata})
        );
    }

    function prepareApproveBaseTokenGovernanceCalls(
        IBridgehub bridgehub,
        address l1SharedBridgeProxy,
        uint256 chainId,
        uint256 amountToApprove
    ) internal view returns (uint256 ethAmountToPass, Call[] memory calls) {
        address baseTokenAddress = bridgehub.baseToken(chainId);
        if (ADDRESS_ONE != baseTokenAddress) {
            console.log("Base token not ETH, approving");
            IERC20 baseToken = IERC20(baseTokenAddress);

            bytes memory approvalCalldata = abi.encodeCall(baseToken.approve, (l1SharedBridgeProxy, amountToApprove));

            calls = new Call[](1);
            calls[0] = Call({target: baseTokenAddress, value: 0, data: approvalCalldata});

            ethAmountToPass = 0;
        } else {
            console.log("Base token is ETH, no need to approve");
            ethAmountToPass = amountToApprove;
        }
    }

    function prepareAdminL1L2DirectTransaction(
        uint256 gasPrice,
        bytes memory l2Calldata,
        uint256 l2GasLimit,
        bytes[] memory factoryDeps,
        address dstAddress,
        uint256 l2Value,
        uint256 chainId,
        address bridgehubAddress,
        address l1SharedBridgeProxy,
        address refundRecipient
    ) internal returns (Call[] memory calls) {
        // 1) Prepare the L2TransactionRequestDirect (same logic as before)
        (
            L2TransactionRequestDirect memory l2TransactionRequestDirect,
            uint256 requiredValueToDeploy
        ) = prepareL1L2Transaction(
                PrepareL1L2TransactionParams({
                    l1GasPrice: gasPrice,
                    l2Calldata: l2Calldata,
                    l2GasLimit: l2GasLimit,
                    l2Value: l2Value,
                    factoryDeps: factoryDeps,
                    dstAddress: dstAddress,
                    chainId: chainId,
                    bridgehubAddress: bridgehubAddress,
                    l1SharedBridgeProxy: l1SharedBridgeProxy,
                    refundRecipient: refundRecipient
                })
            );

        // 2) Prepare approval calls if base token != ETH
        (uint256 ethAmountToPass, Call[] memory approvalCalls) = prepareApproveBaseTokenAdminCalls(
            IBridgehub(bridgehubAddress),
            l1SharedBridgeProxy,
            chainId,
            requiredValueToDeploy
        );

        // 3) Start building up the final calls array
        calls = mergeCalls(calls, approvalCalls);

        // 4) Add the actual requestL2TransactionDirect call to the Bridgehub
        bytes memory l2TransactionRequestDirectCalldata = abi.encodeCall(
            IBridgehub.requestL2TransactionDirect,
            (l2TransactionRequestDirect)
        );

        calls = appendCall(
            calls,
            Call({target: bridgehubAddress, value: ethAmountToPass, data: l2TransactionRequestDirectCalldata})
        );

        return calls;
    }

    function prepareAdminL1L2TwoBridgesTransaction(
        uint256 l1GasPrice,
        uint256 l2GasLimit,
        uint256 chainId,
        address bridgehubAddress,
        address l1SharedBridgeProxy,
        address secondBridgeAddress,
        uint256 secondBridgeValue,
        bytes memory secondBridgeCalldata,
        address refundRecipient
    ) internal returns (Call[] memory calls) {
        // 1) Prepare the L2TransactionRequestTwoBridges (same logic as before)
        (
            L2TransactionRequestTwoBridgesOuter memory l2TransactionRequest,
            uint256 requiredValueToDeploy
        ) = prepareL1L2TransactionTwoBridges(
                l1GasPrice,
                l2GasLimit,
                chainId,
                bridgehubAddress,
                secondBridgeAddress,
                secondBridgeValue,
                secondBridgeCalldata,
                refundRecipient
            );

        // 2) Prepare approval calls if base token != ETH
        (uint256 ethAmountToPass, Call[] memory approvalCalls) = prepareApproveBaseTokenAdminCalls(
            IBridgehub(bridgehubAddress),
            l1SharedBridgeProxy,
            chainId,
            requiredValueToDeploy
        );

        // 3) Merge in the approval calls
        calls = mergeCalls(calls, approvalCalls);

        // 4) Add the actual requestL2TransactionTwoBridges call to the Bridgehub
        bytes memory l2TransactionRequestCalldata = abi.encodeCall(
            IBridgehub.requestL2TransactionTwoBridges,
            (l2TransactionRequest)
        );

        calls = appendCall(
            calls,
            Call({target: bridgehubAddress, value: ethAmountToPass, data: l2TransactionRequestCalldata})
        );

        return calls;
    }

    function runAdminL1L2DirectTransaction(
        uint256 gasPrice,
        address admin,
        address accessControlRestriction,
        bytes memory l2Calldata,
        uint256 l2GasLimit,
        bytes[] memory factoryDeps,
        address dstAddress,
        uint256 chainId,
        address bridgehubAddress,
        address l1SharedBridgeProxy,
        address refundRecipient
    ) internal returns (bytes32 txHash) {
        // 1) Prepare the calls (no actual execution done here)
        Call[] memory calls = prepareAdminL1L2DirectTransaction(
            gasPrice,
            l2Calldata,
            l2GasLimit,
            factoryDeps,
            dstAddress,
            0,
            chainId,
            bridgehubAddress,
            l1SharedBridgeProxy,
            refundRecipient
        );

        console.log("Executing transaction");
        // 2) Record logs before we do the actual execution
        vm.recordLogs();

        // 3) Execute the prepared calls in a single multicall
        adminExecuteCalls(admin, accessControlRestriction, calls);

        // 4) Retrieve logs and parse out the L2 transaction hash
        Vm.Log[] memory logs = vm.getRecordedLogs();
        console.log("Transaction executed successfully! Extracting logs...");

        address expectedDiamondProxyAddress = IBridgehub(bridgehubAddress).getHyperchain(chainId);
        txHash = extractPriorityOpFromLogs(expectedDiamondProxyAddress, logs);

        console.log("L2 Transaction hash is ");
        console.logBytes32(txHash);
    }

    function runAdminL1L2TwoBridgesTransaction(
        uint256 l1GasPrice,
        address admin,
        address accessControlRestriction,
        uint256 l2GasLimit,
        uint256 chainId,
        address bridgehubAddress,
        address l1SharedBridgeProxy,
        address secondBridgeAddress,
        uint256 secondBridgeValue,
        bytes memory secondBridgeCalldata,
        address refundRecipient
    ) internal returns (bytes32 txHash) {
        // 1) Prepare the calls
        Call[] memory calls = prepareAdminL1L2TwoBridgesTransaction(
            l1GasPrice,
            l2GasLimit,
            chainId,
            bridgehubAddress,
            l1SharedBridgeProxy,
            secondBridgeAddress,
            secondBridgeValue,
            secondBridgeCalldata,
            refundRecipient
        );

        console.log("Executing transaction");
        // 2) Record logs
        vm.recordLogs();

        // 3) Execute
        adminExecuteCalls(admin, accessControlRestriction, calls);

        // 4) Retrieve logs and parse out the L2 transaction hash
        Vm.Log[] memory logs = vm.getRecordedLogs();
        console.log("Transaction executed successfully! Extracting logs...");

        address expectedDiamondProxyAddress = IBridgehub(bridgehubAddress).getHyperchain(chainId);
        txHash = extractPriorityOpFromLogs(expectedDiamondProxyAddress, logs);

        console.log("L2 Transaction hash is ");
        console.logBytes32(txHash);
    }

    function prepareApproveBaseTokenAdminCalls(
        IBridgehub bridgehub,
        address l1SharedBridgeProxy,
        uint256 chainId,
        uint256 amountToApprove
    ) internal returns (uint256 ethAmountToPass, Call[] memory calls) {
        address baseTokenAddress = bridgehub.baseToken(chainId);
        if (ADDRESS_ONE != baseTokenAddress) {
            // Base token is not ETH, so we need to create an approval call
            calls = new Call[](1);

            // Build approval calldata
            IERC20 baseToken = IERC20(baseTokenAddress);
            bytes memory approvalCalldata = abi.encodeCall(baseToken.approve, (l1SharedBridgeProxy, amountToApprove));

            calls[0] = Call({target: baseTokenAddress, value: 0, data: approvalCalldata});

            // No ETH needs to be passed, so we return 0
            ethAmountToPass = 0;
        } else {
            // Base token is ETH, no approval call is needed
            calls = new Call[](0);
            // We pass the entire amount as ETH
            ethAmountToPass = amountToApprove;
        }
    }

    function extractAllPriorityOpFromLogs(
        address expectedDiamondProxyAddress,
        Vm.Log[] memory logs
    ) internal pure returns (bytes32[] memory result) {
        // TODO(EVM-749): cleanup the constant and automate its derivation
        bytes32 topic0 = bytes32(uint256(0x4531cd5795773d7101c17bdeb9f5ab7f47d7056017506f937083be5d6e77a382));

        uint256 count = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == expectedDiamondProxyAddress && logs[i].topics[0] == topic0) {
                count += 1;
            }
        }

        result = new bytes32[](count);
        uint256 index = 0;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == expectedDiamondProxyAddress && logs[i].topics[0] == topic0) {
                bytes memory data = logs[i].data;
                bytes32 txHash;
                assembly {
                    // Skip length + tx id
                    txHash := mload(add(data, 0x40))
                }
                result[index++] = txHash;
            }
        }
    }

    function extractPriorityOpFromLogs(
        address expectedDiamondProxyAddress,
        Vm.Log[] memory logs
    ) internal pure returns (bytes32 txHash) {
        bytes32[] memory allLogs = extractAllPriorityOpFromLogs(expectedDiamondProxyAddress, logs);

        if (allLogs.length != 1) {
            revert("Incorrect number of priority logs");
        }

        txHash = allLogs[0];
    }

    /**
     * @dev Publish bytecodes to l2 through l1
     */
    function publishBytecodes(
        bytes[] memory factoryDeps,
        uint256 chainId,
        address bridgehubAddress,
        address l1SharedBridgeProxy
    ) internal {
        runL1L2Transaction({
            l2Calldata: "",
            l2GasLimit: MAX_PRIORITY_TX_GAS,
            l2Value: 0,
            factoryDeps: factoryDeps,
            dstAddress: 0x0000000000000000000000000000000000000000,
            chainId: chainId,
            bridgehubAddress: bridgehubAddress,
            l1SharedBridgeProxy: l1SharedBridgeProxy,
            refundRecipient: msg.sender
        });
    }

    /**
     * @dev Read foundry bytecodes
     */
    function readFoundryBytecode(string memory artifactPath) internal view returns (bytes memory) {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, artifactPath);
        string memory json = vm.readFile(path);
        bytes memory bytecode = vm.parseJsonBytes(json, ".bytecode.object");
        return bytecode;
    }

    function readFoundryBytecodeL1(
        string memory fileName,
        string memory contractName
    ) internal view returns (bytes memory) {
        string memory path = string.concat("/../l1-contracts/out/", fileName, "/", contractName, ".json");
        return readFoundryBytecode(path);
    }

    function readZKFoundryBytecodeL1(
        string memory fileName,
        string memory contractName
    ) internal view returns (bytes memory) {
        string memory path = string.concat("/../l1-contracts/zkout/", fileName, "/", contractName, ".json");
        bytes memory bytecode = readFoundryBytecode(path);
        return bytecode;
    }

    function readZKFoundryBytecodeL2(
        string memory fileName,
        string memory contractName
    ) internal view returns (bytes memory) {
        string memory path = string.concat("/../l2-contracts/zkout/", fileName, "/", contractName, ".json");
        bytes memory bytecode = readFoundryBytecode(path);
        return bytecode;
    }

    function readZKFoundryBytecodeSystemContracts(
        string memory fileName,
        string memory contractName
    ) internal view returns (bytes memory) {
        string memory path = string.concat("/../system-contracts/zkout/", fileName, "/", contractName, ".json");
        bytes memory bytecode = readFoundryBytecode(path);
        return bytecode;
    }

    /**
     * @dev Read hardhat bytecodes
     */
    function readFoundryDeployedBytecode(string memory artifactPath) internal view returns (bytes memory) {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, artifactPath);
        string memory json = vm.readFile(path);
        bytes memory bytecode = vm.parseJsonBytes(json, ".deployedBytecode.object");
        return bytecode;
    }

    function executeUpgrade(
        address _governor,
        bytes32 _salt,
        address _target,
        bytes memory _data,
        uint256 _value,
        uint256 _delay
    ) internal {
        IGovernance governance = IGovernance(_governor);
        IOwnable ownable = IOwnable(_governor);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: _target, value: _value, data: _data});

        executeCalls(_governor, _salt, _delay, calls);
    }

    function executeCalls(address _governor, bytes32 _salt, uint256 _delay, Call[] memory calls) internal {
        IGovernance.Operation memory operation = IGovernance.Operation({
            calls: calls,
            predecessor: bytes32(0),
            salt: _salt
        });

        // Calculate total ETH required
        uint256 totalValue;
        for (uint256 i = 0; i < calls.length; i++) {
            totalValue += calls[i].value;
        }

        vm.startBroadcast(IOwnable(_governor).owner());
        IGovernance(_governor).scheduleTransparent(operation, _delay);
        if (_delay == 0) {
            IGovernance(_governor).execute{value: totalValue}(operation);
        }
        vm.stopBroadcast();
    }

    function encodeChainAdminMulticall(Call[] memory _calls, bool _requireSuccess) internal returns (bytes memory) {
        return abi.encodeCall(IChainAdmin.multicall, (_calls, _requireSuccess));
    }

    function getGuardiansEmergencySignatures(
        Vm.Wallet memory _governorWallet,
        IProtocolUpgradeHandler _protocolUpgradeHandler,
        bytes32 _emergencyUpgradeBoardDigest,
        bytes32 _upgradeId
    ) internal returns (bytes memory fullSignatures) {
        address[] memory guardiansMembers = new address[](8);
        {
            IMultisig guardians = IMultisig(_protocolUpgradeHandler.guardians());
            for (uint256 i = 0; i < 8; i++) {
                guardiansMembers[i] = guardians.members(i);
            }
        }
        bytes[] memory guardiansRawSignatures = new bytes[](8);
        for (uint256 i = 0; i < 8; i++) {
            bytes32 safeDigest;
            {
                bytes32 guardiansDigest = EIP712Utils.buildDigest(
                    _emergencyUpgradeBoardDigest,
                    keccak256(abi.encode(EXECUTE_EMERGENCY_UPGRADE_GUARDIANS_TYPEHASH, _upgradeId))
                );
                safeDigest = ISafe(guardiansMembers[i]).getMessageHash(abi.encode(guardiansDigest));
            }

            (uint8 v, bytes32 r, bytes32 s) = vm.sign(_governorWallet, safeDigest);
            guardiansRawSignatures[i] = abi.encodePacked(r, s, v);
        }

        fullSignatures = abi.encode(guardiansMembers, guardiansRawSignatures);
    }

    function getSecurityCouncilEmergencySignatures(
        Vm.Wallet memory _governorWallet,
        IProtocolUpgradeHandler _protocolUpgradeHandler,
        bytes32 _emergencyUpgradeBoardDigest,
        bytes32 _upgradeId
    ) internal returns (bytes memory fullSignatures) {
        address[] memory securityCouncilMembers = new address[](SECURITY_COUNCIL_SIZE);
        {
            IMultisig securityCouncil = IMultisig(_protocolUpgradeHandler.securityCouncil());
            for (uint256 i = 0; i < SECURITY_COUNCIL_SIZE; i++) {
                securityCouncilMembers[i] = securityCouncil.members(i);
            }
        }
        bytes[] memory securityCouncilRawSignatures = new bytes[](SECURITY_COUNCIL_SIZE);
        for (uint256 i = 0; i < securityCouncilMembers.length; i++) {
            bytes32 safeDigest;
            {
                bytes32 securityCouncilDigest = EIP712Utils.buildDigest(
                    _emergencyUpgradeBoardDigest,
                    keccak256(abi.encode(EXECUTE_EMERGENCY_UPGRADE_SECURITY_COUNCIL_TYPEHASH, _upgradeId))
                );
                safeDigest = ISafe(securityCouncilMembers[i]).getMessageHash(abi.encode(securityCouncilDigest));
            }
            {
                (uint8 v, bytes32 r, bytes32 s) = vm.sign(_governorWallet, safeDigest);
                securityCouncilRawSignatures[i] = abi.encodePacked(r, s, v);
            }
        }
        fullSignatures = abi.encode(securityCouncilMembers, securityCouncilRawSignatures);
    }

    function getZKFoundationEmergencySignature(
        Vm.Wallet memory _governorWallet,
        IProtocolUpgradeHandler _protocolUpgradeHandler,
        bytes32 _emergencyUpgradeBoardDigest,
        bytes32 _upgradeId
    ) internal returns (bytes memory fullSignatures) {
        ISafe zkFoundation;
        IEmergencyUpgrageBoard emergencyUpgradeBoard = IEmergencyUpgrageBoard(
            _protocolUpgradeHandler.emergencyUpgradeBoard()
        );
        zkFoundation = ISafe(emergencyUpgradeBoard.ZK_FOUNDATION_SAFE());

        bytes32 zkFoundationDigest = EIP712Utils.buildDigest(
            _emergencyUpgradeBoardDigest,
            keccak256(abi.encode(EXECUTE_EMERGENCY_UPGRADE_ZK_FOUNDATION_TYPEHASH, _upgradeId))
        );
        bytes32 safeDigest = ISafe(zkFoundation).getMessageHash(abi.encode(zkFoundationDigest));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_governorWallet, safeDigest);
        fullSignatures = abi.encodePacked(r, s, v);
    }

    function executeEmergencyProtocolUpgrade(
        IProtocolUpgradeHandler _protocolUpgradeHandler,
        Vm.Wallet memory _governorWallet,
        IProtocolUpgradeHandler.Call[] memory _calls,
        bytes32 _salt
    ) internal returns (bytes memory) {
        bytes32 upgradeId;
        bytes32 emergencyUpgradeBoardDigest;
        {
            address emergencyUpgradeBoard = _protocolUpgradeHandler.emergencyUpgradeBoard();
            IProtocolUpgradeHandler.UpgradeProposal memory upgradeProposal = IProtocolUpgradeHandler.UpgradeProposal({
                calls: _calls,
                salt: _salt,
                executor: emergencyUpgradeBoard
            });
            upgradeId = keccak256(abi.encode(upgradeProposal));
            emergencyUpgradeBoardDigest = EIP712Utils.buildDomainHash(
                emergencyUpgradeBoard,
                "EmergencyUpgradeBoard",
                "1"
            );
        }

        bytes memory guardiansSignatures = getGuardiansEmergencySignatures(
            _governorWallet,
            _protocolUpgradeHandler,
            emergencyUpgradeBoardDigest,
            upgradeId
        );

        bytes memory securityCouncilSignatures = getSecurityCouncilEmergencySignatures(
            _governorWallet,
            _protocolUpgradeHandler,
            emergencyUpgradeBoardDigest,
            upgradeId
        );

        bytes memory zkFoundationSignature = getZKFoundationEmergencySignature(
            _governorWallet,
            _protocolUpgradeHandler,
            emergencyUpgradeBoardDigest,
            upgradeId
        );

        {
            vm.startBroadcast();
            IEmergencyUpgrageBoard emergencyUpgradeBoard = IEmergencyUpgrageBoard(
                _protocolUpgradeHandler.emergencyUpgradeBoard()
            );
            // solhint-disable-next-line func-named-parameters
            emergencyUpgradeBoard.executeEmergencyUpgrade(
                _calls,
                _salt,
                guardiansSignatures,
                securityCouncilSignatures,
                zkFoundationSignature
            );
            vm.stopBroadcast();
        }
    }

    // Signs and approves the upgrade by the security council.
    // It works only on staging env, since the `_governorWallet` must be the wallet
    // that is the sole owner of the Gnosis wallets that constitute the security council.
    function securityCouncilApproveUpgrade(
        IProtocolUpgradeHandler _protocolUpgradeHandler,
        Vm.Wallet memory _governorWallet,
        bytes32 upgradeId
    ) internal {
        address securityCouncilAddr = _protocolUpgradeHandler.securityCouncil();
        bytes32 securityCouncilDigest;
        {
            securityCouncilDigest = EIP712Utils.buildDomainHash(securityCouncilAddr, "SecurityCouncil", "1");
        }

        bytes[] memory securityCouncilRawSignatures = new bytes[](SECURITY_COUNCIL_SIZE);
        address[] memory securityCouncilMembers = new address[](12);
        {
            {
                IMultisig securityCouncil = IMultisig(_protocolUpgradeHandler.securityCouncil());
                for (uint256 i = 0; i < 12; i++) {
                    securityCouncilMembers[i] = securityCouncil.members(i);
                }
            }
            for (uint256 i = 0; i < securityCouncilMembers.length; i++) {
                bytes32 safeDigest;
                {
                    bytes32 digest = EIP712Utils.buildDigest(
                        securityCouncilDigest,
                        keccak256(abi.encode(APPROVE_UPGRADE_SECURITY_COUNCIL_TYPEHASH, upgradeId))
                    );
                    safeDigest = ISafe(securityCouncilMembers[i]).getMessageHash(abi.encode(digest));
                }
                {
                    (uint8 v, bytes32 r, bytes32 s) = vm.sign(_governorWallet, safeDigest);
                    securityCouncilRawSignatures[i] = abi.encodePacked(r, s, v);
                }
            }
        }

        {
            vm.startBroadcast(msg.sender);
            ISecurityCouncil(securityCouncilAddr).approveUpgradeSecurityCouncil(
                upgradeId,
                securityCouncilMembers,
                securityCouncilRawSignatures
            );
            vm.stopBroadcast();
        }
    }

    function adminExecute(
        address _admin,
        address _accessControlRestriction,
        address _target,
        bytes memory _data,
        uint256 _value
    ) internal {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: _target, value: _value, data: _data});

        adminExecuteCalls(_admin, _accessControlRestriction, calls);
    }

    function adminExecuteCalls(address _admin, address _accessControlRestriction, Call[] memory calls) internal {
        // If `_accessControlRestriction` is not provided, we assume that `_admin` is IOwnable
        address adminOwner = _accessControlRestriction == address(0)
            ? IOwnable(_admin).owner()
            : IAccessControlDefaultAdminRules(_accessControlRestriction).defaultAdmin();

        // Calculate total ETH required
        uint256 totalValue;
        for (uint256 i = 0; i < calls.length; i++) {
            totalValue += calls[i].value;
        }

        vm.startBroadcast(adminOwner);
        IChainAdmin(_admin).multicall{value: totalValue}(calls, true);
        vm.stopBroadcast();
    }

    function chainInfoFromBridgehubAndChainId(
        address _bridgehub,
        uint256 _chainId
    ) internal view returns (ChainInfoFromBridgehub memory info) {
        info.l1AssetRouterProxy = Bridgehub(_bridgehub).assetRouter();
        info.diamondProxy = Bridgehub(_bridgehub).getZKChain(_chainId);
        info.admin = IGetters(info.diamondProxy).getAdmin();
        info.ctm = Bridgehub(_bridgehub).chainTypeManager(_chainId);
        info.serverNotifier = ChainTypeManager(info.ctm).serverNotifierAddress();
    }

    function readRollupDAValidatorBytecode() internal view returns (bytes memory bytecode) {
        bytecode = readFoundryBytecode("/../da-contracts/out/RollupL1DAValidator.sol/RollupL1DAValidator.json");
    }

    function readAvailL1DAValidatorBytecode() internal view returns (bytes memory bytecode) {
        bytecode = readFoundryBytecode("/../da-contracts/out/AvailL1DAValidator.sol/AvailL1DAValidator.json");
    }

    function readDummyAvailBridgeBytecode() internal view returns (bytes memory bytecode) {
        bytecode = readFoundryBytecode("/../da-contracts/out/DummyAvailBridge.sol/DummyAvailBridge.json");
    }

    function mergeCalls(Call[] memory a, Call[] memory b) public pure returns (Call[] memory result) {
        result = new Call[](a.length + b.length);
        for (uint256 i = 0; i < a.length; i++) {
            result[i] = a[i];
        }
        for (uint256 i = 0; i < b.length; i++) {
            result[a.length + i] = b[i];
        }
    }

    function appendCall(Call[] memory a, Call memory b) public pure returns (Call[] memory result) {
        result = new Call[](a.length + 1);
        for (uint256 i = 0; i < a.length; i++) {
            result[i] = a[i];
        }
        result[a.length] = b;
    }

    // add this to be excluded from coverage report
    function test() internal {}
}
