// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// solhint-disable gas-custom-errors, reason-string

import {Vm} from "forge-std/Vm.sol";
import {console2 as console} from "forge-std/Script.sol";

import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {L2TransactionRequestDirect, L2TransactionRequestTwoBridgesOuter} from "contracts/bridgehub/IBridgehub.sol";
import {IGovernance} from "contracts/governance/IGovernance.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {Call} from "contracts/governance/Common.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";
import {L2_DEPLOYER_SYSTEM_CONTRACT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {L2ContractHelper} from "contracts/common/libraries/L2ContractHelper.sol";
import {IChainAdmin} from "contracts/governance/IChainAdmin.sol";
import {EIP712Utils} from "./EIP712Utils.sol";
import {IProtocolUpgradeHandler} from "./interfaces/IProtocolUpgradeHandler.sol";
import {IEmergencyUpgrageBoard} from "./interfaces/IEmergencyUpgrageBoard.sol";
import {IMultisig} from "./interfaces/IMultisig.sol";
import {ISafe} from "./interfaces/ISafe.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";

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

/// @dev The offset from which the built-in, but user space contracts are located.
uint160 constant USER_CONTRACTS_OFFSET = 0x10000; // 2^16

// address constant
address constant L2_BRIDGEHUB_ADDRESS = address(USER_CONTRACTS_OFFSET + 0x02);
address constant L2_ASSET_ROUTER_ADDRESS = address(USER_CONTRACTS_OFFSET + 0x03);
address constant L2_NATIVE_TOKEN_VAULT_ADDRESS = address(USER_CONTRACTS_OFFSET + 0x04);
address constant L2_MESSAGE_ROOT_ADDRESS = address(USER_CONTRACTS_OFFSET + 0x05);
address constant L2_WETH_IMPL_ADDRESS = address(USER_CONTRACTS_OFFSET + 0x07);

address constant L2_CREATE2_FACTORY_ADDRESS = address(USER_CONTRACTS_OFFSET);

// solhint-disable-next-line gas-struct-packing
struct StateTransitionDeployedAddresses {
    address chainTypeManagerProxy;
    address chainTypeManagerImplementation;
    address verifier;
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
}

library Utils {
    // Cheatcodes address, 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D.
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    Vm internal constant vm = Vm(VM_ADDRESS);
    // Create2Factory deterministic bytecode.
    // https://github.com/Arachnid/deterministic-deployment-proxy
    bytes internal constant CREATE2_FACTORY_BYTECODE =
        hex"604580600e600039806000f350fe7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    address internal constant ADDRESS_ONE = 0x0000000000000000000000000000000000000001;
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
        return vm.readFileBinary("../system-contracts/bootloader/build/artifacts/proved_batch.yul.zbin");
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
        string memory file = vm.readFile(
            // solhint-disable-next-line func-named-parameters
            string.concat(
                "../system-contracts/artifacts-zk/contracts-preprocessed/",
                filename,
                ".sol/",
                filename,
                ".json"
            )
        );
        bytes memory bytecode = vm.parseJsonBytes(file, "$.bytecode");
        return bytecode;
    }

    /**
     * @dev Returns the bytecode of a given system contract.
     */
    function readPrecompileBytecode(string memory filename) internal view returns (bytes memory) {
        // It is the only exceptional case
        if (keccak256(abi.encodePacked(filename)) == keccak256(abi.encodePacked("EventWriter"))) {
            return
                vm.readFileBinary(
                    // solhint-disable-next-line func-named-parameters
                    string.concat("../system-contracts/contracts-preprocessed/artifacts/", filename, ".yul.zbin")
                );
        }

        return
            vm.readFileBinary(
                // solhint-disable-next-line func-named-parameters
                string.concat(
                    "../system-contracts/contracts-preprocessed/precompiles/artifacts/",
                    filename,
                    ".yul.zbin"
                )
            );
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
            l1SharedBridgeProxy: l1SharedBridgeProxy
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
            l1SharedBridgeProxy: l1SharedBridgeProxy
        });
        return contractAddress;
    }

    function prepareL1L2Transaction(
        PrepareL1L2TransactionParams memory params
    ) internal returns (L2TransactionRequestDirect memory l2TransactionRequestDirect, uint256 requiredValueToDeploy) {
        Bridgehub bridgehub = Bridgehub(params.bridgehubAddress);

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
            refundRecipient: msg.sender
        });
    }

    function prepareL1L2TransactionTwoBridges(
        uint256 l1GasPrice,
        uint256 l2GasLimit,
        uint256 chainId,
        address bridgehubAddress,
        address secondBridgeAddress,
        uint256 secondBridgeValue,
        bytes memory secondBridgeCalldata
    )
        internal
        returns (L2TransactionRequestTwoBridgesOuter memory l2TransactionRequest, uint256 requiredValueToDeploy)
    {
        Bridgehub bridgehub = Bridgehub(bridgehubAddress);

        requiredValueToDeploy =
            bridgehub.l2TransactionBaseCost(chainId, l1GasPrice, l2GasLimit, REQUIRED_L2_GAS_PRICE_PER_PUBDATA) *
            2;

        l2TransactionRequest = L2TransactionRequestTwoBridgesOuter({
            chainId: chainId,
            mintValue: requiredValueToDeploy,
            l2Value: 0,
            l2GasLimit: l2GasLimit,
            l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            refundRecipient: msg.sender,
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
        address l1SharedBridgeProxy
    ) internal {
        Bridgehub bridgehub = Bridgehub(bridgehubAddress);
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
                    l1SharedBridgeProxy: l1SharedBridgeProxy
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

    function runGovernanceL1L2DirectTransaction(
        uint256 l1GasPrice,
        address governor,
        bytes32 salt,
        bytes memory l2Calldata,
        uint256 l2GasLimit,
        bytes[] memory factoryDeps,
        address dstAddress,
        uint256 chainId,
        address bridgehubAddress,
        address l1SharedBridgeProxy
    ) internal returns (bytes32 txHash) {
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
                    l1SharedBridgeProxy: l1SharedBridgeProxy
                })
            );

        requiredValueToDeploy = approveBaseTokenGovernance(
            Bridgehub(bridgehubAddress),
            l1SharedBridgeProxy,
            governor,
            salt,
            chainId,
            requiredValueToDeploy
        );

        bytes memory l2TransactionRequestDirectCalldata = abi.encodeCall(
            Bridgehub.requestL2TransactionDirect,
            (l2TransactionRequestDirect)
        );

        console.log("Executing transaction");
        vm.recordLogs();
        executeUpgrade(governor, salt, bridgehubAddress, l2TransactionRequestDirectCalldata, requiredValueToDeploy, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        console.log("Transaction executed succeassfully! Extracting logs...");

        address expectedDiamondProxyAddress = Bridgehub(bridgehubAddress).getHyperchain(chainId);

        txHash = extractPriorityOpFromLogs(expectedDiamondProxyAddress, logs);

        console.log("L2 Transaction hash is ");
        console.logBytes32(txHash);
    }

    function runGovernanceL1L2TwoBridgesTransaction(
        uint256 l1GasPrice,
        address governor,
        bytes32 salt,
        uint256 l2GasLimit,
        uint256 chainId,
        address bridgehubAddress,
        address l1SharedBridgeProxy,
        address secondBridgeAddress,
        uint256 secondBridgeValue,
        bytes memory secondBridgeCalldata
    ) internal returns (bytes32 txHash) {
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
                secondBridgeCalldata
            );

        requiredValueToDeploy = approveBaseTokenGovernance(
            Bridgehub(bridgehubAddress),
            l1SharedBridgeProxy,
            governor,
            salt,
            chainId,
            requiredValueToDeploy
        );

        bytes memory l2TransactionRequestCalldata = abi.encodeCall(
            Bridgehub.requestL2TransactionTwoBridges,
            (l2TransactionRequest)
        );

        console.log("Executing transaction");
        vm.recordLogs();
        executeUpgrade(governor, salt, bridgehubAddress, l2TransactionRequestCalldata, requiredValueToDeploy, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        console.log("Transaction executed succeassfully! Extracting logs...");

        address expectedDiamondProxyAddress = Bridgehub(bridgehubAddress).getHyperchain(chainId);

        txHash = extractPriorityOpFromLogs(expectedDiamondProxyAddress, logs);

        console.log("L2 Transaction hash is ");
        console.logBytes32(txHash);
    }

    function approveBaseTokenGovernance(
        Bridgehub bridgehub,
        address l1SharedBridgeProxy,
        address governor,
        bytes32 salt,
        uint256 chainId,
        uint256 amountToApprove
    ) internal returns (uint256 ethAmountToPass) {
        address baseTokenAddress = bridgehub.baseToken(chainId);
        if (ADDRESS_ONE != baseTokenAddress) {
            console.log("Base token not ETH, approving");
            IERC20 baseToken = IERC20(baseTokenAddress);

            bytes memory approvalCalldata = abi.encodeCall(baseToken.approve, (l1SharedBridgeProxy, amountToApprove));

            executeUpgrade(governor, salt, address(baseToken), approvalCalldata, 0, 0);

            ethAmountToPass = 0;
        } else {
            console.log("Base token is ETH, no need to approve");
            ethAmountToPass = amountToApprove;
        }
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
        address l1SharedBridgeProxy
    ) internal returns (bytes32 txHash) {
        (
            L2TransactionRequestDirect memory l2TransactionRequestDirect,
            uint256 requiredValueToDeploy
        ) = prepareL1L2Transaction(
                PrepareL1L2TransactionParams({
                    l1GasPrice: gasPrice,
                    l2Calldata: l2Calldata,
                    l2GasLimit: l2GasLimit,
                    l2Value: 0,
                    factoryDeps: factoryDeps,
                    dstAddress: dstAddress,
                    chainId: chainId,
                    bridgehubAddress: bridgehubAddress,
                    l1SharedBridgeProxy: l1SharedBridgeProxy
                })
            );

        requiredValueToDeploy = approveBaseTokenAdmin(
            Bridgehub(bridgehubAddress),
            l1SharedBridgeProxy,
            admin,
            accessControlRestriction,
            chainId,
            requiredValueToDeploy
        );

        bytes memory l2TransactionRequestDirectCalldata = abi.encodeCall(
            Bridgehub.requestL2TransactionDirect,
            (l2TransactionRequestDirect)
        );

        console.log("Executing transaction");
        vm.recordLogs();
        adminExecute(
            admin,
            accessControlRestriction,
            bridgehubAddress,
            l2TransactionRequestDirectCalldata,
            requiredValueToDeploy
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        console.log("Transaction executed succeassfully! Extracting logs...");

        address expectedDiamondProxyAddress = Bridgehub(bridgehubAddress).getHyperchain(chainId);

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
        bytes memory secondBridgeCalldata
    ) internal returns (bytes32 txHash) {
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
                secondBridgeCalldata
            );

        requiredValueToDeploy = approveBaseTokenAdmin(
            Bridgehub(bridgehubAddress),
            l1SharedBridgeProxy,
            admin,
            accessControlRestriction,
            chainId,
            requiredValueToDeploy
        );

        bytes memory l2TransactionRequestCalldata = abi.encodeCall(
            Bridgehub.requestL2TransactionTwoBridges,
            (l2TransactionRequest)
        );

        console.log("Executing transaction");
        vm.recordLogs();
        adminExecute(
            admin,
            accessControlRestriction,
            bridgehubAddress,
            l2TransactionRequestCalldata,
            requiredValueToDeploy
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        console.log("Transaction executed succeassfully! Extracting logs...");

        address expectedDiamondProxyAddress = Bridgehub(bridgehubAddress).getHyperchain(chainId);

        txHash = extractPriorityOpFromLogs(expectedDiamondProxyAddress, logs);

        console.log("L2 Transaction hash is ");
        console.logBytes32(txHash);
    }

    function approveBaseTokenAdmin(
        Bridgehub bridgehub,
        address l1SharedBridgeProxy,
        address admin,
        address accessControlRestriction,
        uint256 chainId,
        uint256 amountToApprove
    ) internal returns (uint256 ethAmountToPass) {
        address baseTokenAddress = bridgehub.baseToken(chainId);
        if (ADDRESS_ONE != baseTokenAddress) {
            console.log("Base token not ETH, approving");
            IERC20 baseToken = IERC20(baseTokenAddress);

            bytes memory approvalCalldata = abi.encodeCall(baseToken.approve, (l1SharedBridgeProxy, amountToApprove));

            adminExecute(admin, accessControlRestriction, address(baseToken), approvalCalldata, 0);

            ethAmountToPass = 0;
        } else {
            console.log("Base token is ETH, no need to approve");
            ethAmountToPass = amountToApprove;
        }
    }

    function extractPriorityOpFromLogs(
        address expectedDiamondProxyAddress,
        Vm.Log[] memory logs
    ) internal pure returns (bytes32 txHash) {
        // TODO(EVM-749): cleanup the constant and automate its derivation
        bytes32 topic0 = bytes32(uint256(0x4531cd5795773d7101c17bdeb9f5ab7f47d7056017506f937083be5d6e77a382));

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == expectedDiamondProxyAddress && logs[i].topics[0] == topic0) {
                if (txHash != bytes32(0)) {
                    revert("Multiple priority ops");
                }

                bytes memory data = logs[i].data;
                assembly {
                    // Skip length + tx id
                    txHash := mload(add(data, 0x40))
                }
            }
        }

        if (txHash == bytes32(0)) {
            revert("No priority op found");
        }
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
            l1SharedBridgeProxy: l1SharedBridgeProxy
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

    function readZKFoundryBytecode(
        string memory fileName,
        string memory contractName
    ) internal view returns (bytes memory) {
        string memory path = string.concat("/../l1-contracts/zkout/", fileName, "/", contractName, ".json");
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
        Ownable ownable = Ownable(_governor);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: _target, value: _value, data: _data});

        IGovernance.Operation memory operation = IGovernance.Operation({
            calls: calls,
            predecessor: bytes32(0),
            salt: _salt
        });

        vm.startBroadcast(ownable.owner());
        governance.scheduleTransparent(operation, _delay);
        if (_delay == 0) {
            governance.execute{value: _value}(operation);
        }
        vm.stopBroadcast();
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

        bytes memory guardiansSignatures;
        {
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
                        emergencyUpgradeBoardDigest,
                        keccak256(abi.encode(EXECUTE_EMERGENCY_UPGRADE_GUARDIANS_TYPEHASH, upgradeId))
                    );
                    safeDigest = ISafe(guardiansMembers[i]).getMessageHash(abi.encode(guardiansDigest));
                }

                (uint8 v, bytes32 r, bytes32 s) = vm.sign(_governorWallet, safeDigest);
                guardiansRawSignatures[i] = abi.encodePacked(r, s, v);
            }
            guardiansSignatures = abi.encode(guardiansMembers, guardiansRawSignatures);
        }

        bytes memory securityCouncilSignatures;
        {
            address[] memory securityCouncilMembers = new address[](12);
            {
                IMultisig securityCouncil = IMultisig(_protocolUpgradeHandler.securityCouncil());
                for (uint256 i = 0; i < 12; i++) {
                    securityCouncilMembers[i] = securityCouncil.members(i);
                }
            }
            bytes[] memory securityCouncilRawSignatures = new bytes[](12);
            for (uint256 i = 0; i < securityCouncilMembers.length; i++) {
                bytes32 safeDigest;
                {
                    bytes32 securityCouncilDigest = EIP712Utils.buildDigest(
                        emergencyUpgradeBoardDigest,
                        keccak256(abi.encode(EXECUTE_EMERGENCY_UPGRADE_SECURITY_COUNCIL_TYPEHASH, upgradeId))
                    );
                    safeDigest = ISafe(securityCouncilMembers[i]).getMessageHash(abi.encode(securityCouncilDigest));
                }
                {
                    (uint8 v, bytes32 r, bytes32 s) = vm.sign(_governorWallet, safeDigest);
                    securityCouncilRawSignatures[i] = abi.encodePacked(r, s, v);
                }
            }
            securityCouncilSignatures = abi.encode(securityCouncilMembers, securityCouncilRawSignatures);
        }

        bytes memory zkFoundationSignature;
        {
            ISafe zkFoundation;
            {
                IEmergencyUpgrageBoard emergencyUpgradeBoard = IEmergencyUpgrageBoard(
                    _protocolUpgradeHandler.emergencyUpgradeBoard()
                );
                zkFoundation = ISafe(emergencyUpgradeBoard.ZK_FOUNDATION_SAFE());
            }
            bytes32 zkFoundationDigest = EIP712Utils.buildDigest(
                emergencyUpgradeBoardDigest,
                keccak256(abi.encode(EXECUTE_EMERGENCY_UPGRADE_ZK_FOUNDATION_TYPEHASH, upgradeId))
            );
            bytes32 safeDigest = ISafe(zkFoundation).getMessageHash(abi.encode(zkFoundationDigest));
            {
                (uint8 v, bytes32 r, bytes32 s) = vm.sign(_governorWallet, safeDigest);
                zkFoundationSignature = abi.encodePacked(r, s, v);
            }
        }

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

    function adminExecute(
        address _admin,
        address _accessControlRestriction,
        address _target,
        bytes memory _data,
        uint256 _value
    ) internal {
        address defaultAdmin = AccessControlRestriction(_accessControlRestriction).defaultAdmin();

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: _target, value: _value, data: _data});

        vm.startBroadcast(defaultAdmin);
        IChainAdmin(_admin).multicall{value: _value}(calls, true);
        vm.stopBroadcast();
    }

    function readRollupDAValidatorBytecode() internal view returns (bytes memory bytecode) {
        bytecode = readFoundryBytecode("/../da-contracts/out/RollupL1DAValidator.sol/RollupL1DAValidator.json");
    }

    // add this to be excluded from coverage report
    function test() internal {}
}
