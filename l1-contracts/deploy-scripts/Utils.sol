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
import {Call} from "contracts/governance/Common.sol";

/// @dev The offset from which the built-in, but user space contracts are located.
uint160 constant USER_CONTRACTS_OFFSET = 0x10000; // 2^16

// address constant
address constant L2_BRIDGEHUB_ADDRESS = address(USER_CONTRACTS_OFFSET + 0x02);
address constant L2_ASSET_ROUTER_ADDRESS = address(USER_CONTRACTS_OFFSET + 0x03);
address constant L2_NATIVE_TOKEN_VAULT_ADDRESS = address(USER_CONTRACTS_OFFSET + 0x04);
address constant L2_MESSAGE_ROOT_ADDRESS = address(USER_CONTRACTS_OFFSET + 0x05);

struct L2ContractsBytecodes {
    bytes bridgehub;
    bytes l2NativeTokenVault;
    bytes l2AssetRouter;
    bytes messageRoot;
    bytes upgradableBeacon;
    bytes beaconProxy;
    bytes standardErc20;
    bytes transparentUpgradeableProxy;
    bytes forceDeployUpgrader;
    bytes rollupL2DAValidator;
    bytes validiumL2DAValidator;
    bytes chainTypeManager;
    bytes adminFacet;
    bytes mailboxFacet;
    bytes executorFacet;
    bytes gettersFacet;
    bytes diamondInit;
    bytes verifier;
    bytes testnetVerifier;
    bytes validatorTimelock;
    bytes diamondProxy;
    bytes l1Genesis;
    bytes defaultUpgrade;
    bytes multicall3;
    bytes relayedSLDAValidator;
    bytes l2LegacySharedBridge;
}

struct DAContractBytecodes {
    bytes rollupL1DAValidator;
    bytes validiumL1DAValidator;
}

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
    // TODO: delete the last field it is never really used
    address diamondProxy;
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
        // FIXME: use forge to read the bytecode
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
        console.log(path);
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
        bytes memory bytecode = vm.parseJson(file, "$.bytecode");
        return bytecode;
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
        require(child != address(0), "Failed to deploy Create2Factory");
        require(child.code.length > 0, "Failed to deploy Create2Factory");
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
        bytes32 bytecodeHash = L2ContractHelper.hashL2Bytecode(bytecode);

        bytes memory deployData = abi.encodeWithSignature(
            "create2(bytes32,bytes32,bytes)",
            create2salt,
            bytecodeHash,
            constructorargs
        );

        address contractAddress = L2ContractHelper.computeCreate2Address(
            msg.sender,
            create2salt,
            bytecodeHash,
            keccak256(constructorargs)
        );

        uint256 factoryDepsLength = factoryDeps.length;

        bytes[] memory _factoryDeps = new bytes[](factoryDepsLength + 1);

        for (uint256 i = 0; i < factoryDepsLength; ++i) {
            _factoryDeps[i] = factoryDeps[i];
        }
        _factoryDeps[factoryDepsLength] = bytecode;

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

    function prepareL1L2Transaction(
        uint256 l1GasPrice,
        bytes memory l2Calldata,
        uint256 l2GasLimit,
        uint256 l2Value,
        bytes[] memory factoryDeps,
        address dstAddress,
        uint256 chainId,
        address bridgehubAddress,
        address l1SharedBridgeProxy
    ) internal returns (L2TransactionRequestDirect memory l2TransactionRequestDirect, uint256 requiredValueToDeploy) {
        Bridgehub bridgehub = Bridgehub(bridgehubAddress);

        requiredValueToDeploy =
            bridgehub.l2TransactionBaseCost(chainId, l1GasPrice, l2GasLimit, REQUIRED_L2_GAS_PRICE_PER_PUBDATA) *
            2 + l2Value;

        l2TransactionRequestDirect = L2TransactionRequestDirect({
            chainId: chainId,
            mintValue: requiredValueToDeploy,
            l2Contract: dstAddress,
            l2Value: l2Value,
            l2Calldata: l2Calldata,
            l2GasLimit: l2GasLimit,
            l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            factoryDeps: factoryDeps,
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
                bytesToUint256(vm.rpc("eth_gasPrice", "[]")),
                l2Calldata,
                l2GasLimit,
                l2Value,
                factoryDeps,
                dstAddress,
                chainId,
                bridgehubAddress,
                l1SharedBridgeProxy
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
                l1GasPrice,
                l2Calldata,
                l2GasLimit,
                0,
                factoryDeps,
                dstAddress,
                chainId,
                bridgehubAddress,
                l1SharedBridgeProxy
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

        bytes memory l2TransactionRequesCalldata = abi.encodeCall(
            Bridgehub.requestL2TransactionTwoBridges,
            (l2TransactionRequest)
        );

        console.log("Executing transaction");
        vm.recordLogs();
        executeUpgrade(governor, salt, bridgehubAddress, l2TransactionRequesCalldata, requiredValueToDeploy, 0);
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
                gasPrice,
                l2Calldata,
                l2GasLimit,
                0,
                factoryDeps,
                dstAddress,
                chainId,
                bridgehubAddress,
                l1SharedBridgeProxy
            );

        requiredValueToDeploy = approveBaseTokenAdmin(Bridgehub(bridgehubAddress), l1SharedBridgeProxy, admin, chainId, requiredValueToDeploy);

        bytes memory l2TransactionRequestDirectCalldata = abi.encodeCall(
            Bridgehub.requestL2TransactionDirect,
            (l2TransactionRequestDirect)
        );

        console.log("Executing transaction");
        vm.recordLogs();
        adminExecute(admin, bridgehubAddress, l2TransactionRequestDirectCalldata, requiredValueToDeploy);
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
            chainId,
            requiredValueToDeploy
        );

        bytes memory l2TransactionRequesCalldata = abi.encodeCall(
            Bridgehub.requestL2TransactionTwoBridges,
            (l2TransactionRequest)
        );

        console.log("Executing transaction");
        vm.recordLogs();
        adminExecute(admin, bridgehubAddress, l2TransactionRequesCalldata, requiredValueToDeploy);
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
        uint256 chainId,
        uint256 amountToApprove
    ) internal returns (uint256 ethAmountToPass) {
        address baseTokenAddress = bridgehub.baseToken(chainId);
        if (ADDRESS_ONE != baseTokenAddress) {
            console.log("Base token not ETH, approving");
            IERC20 baseToken = IERC20(baseTokenAddress);

            bytes memory approvalCalldata = abi.encodeCall(baseToken.approve, (l1SharedBridgeProxy, amountToApprove));

            adminExecute(admin, address(baseToken), approvalCalldata, 0);

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
        // FIXME: maybe make it less magial
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

    function adminExecute(
        address _admin,
        address _target,
        bytes memory _data,
        uint256 _value
    ) internal {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: _target, value: _value, data: _data});

        vm.startBroadcast();
        IChainAdmin(_admin).multicall{value: _value}(calls, true);
        vm.stopBroadcast();
    }

    /// @notice A helper function that reads all L2 bytecodes at once.
    function readL2ContractsBytecodes() internal view returns (L2ContractsBytecodes memory bytecodes) {
        //HACK: Meanwhile we are not integrated foundry zksync we use contracts that has been built using hardhat

        // One liner creation is preferrable to creating in separate lines
        // to ensure that all contracts' bytecodes were filled up
        bytecodes = L2ContractsBytecodes({
            bridgehub: Utils.readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/bridgehub/Bridgehub.sol/Bridgehub.json"
            ),
            l2NativeTokenVault: readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/bridge/ntv/L2NativeTokenVault.sol/L2NativeTokenVault.json"
            ),
            l2AssetRouter: readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/bridge/asset-router/L2AssetRouter.sol/L2AssetRouter.json"
            ),
            messageRoot: readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/bridgehub/MessageRoot.sol/MessageRoot.json"
            ),
            upgradableBeacon: readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol/UpgradeableBeacon.json"
            ),
            beaconProxy: readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/@openzeppelin/contracts-v4/proxy/beacon/BeaconProxy.sol/BeaconProxy.json"
            ),
            standardErc20: readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/bridge/BridgedStandardERC20.sol/BridgedStandardERC20.json"
            ),
            transparentUpgradeableProxy: readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol/TransparentUpgradeableProxy.json"
            ),
            forceDeployUpgrader: readHardhatBytecode(
                "/../l2-contracts/artifacts-zk/contracts/ForceDeployUpgrader.sol/ForceDeployUpgrader.json"
            ),
            rollupL2DAValidator: readHardhatBytecode(
                "/../l2-contracts/artifacts-zk/contracts/data-availability/RollupL2DAValidator.sol/RollupL2DAValidator.json"
            ),
            validiumL2DAValidator: readHardhatBytecode(
                "/../l2-contracts/artifacts-zk/contracts/data-availability/ValidiumL2DAValidator.sol/ValidiumL2DAValidator.json"
            ),
            chainTypeManager: readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/state-transition/ChainTypeManager.sol/ChainTypeManager.json"
            ),
            adminFacet: readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/state-transition/chain-deps/facets/Admin.sol/AdminFacet.json"
            ),
            mailboxFacet: readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/state-transition/chain-deps/facets/Mailbox.sol/MailboxFacet.json"
            ),
            executorFacet: readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/state-transition/chain-deps/facets/Executor.sol/ExecutorFacet.json"
            ),
            gettersFacet: readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/state-transition/chain-deps/facets/Getters.sol/GettersFacet.json"
            ),
            verifier: readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/state-transition/Verifier.sol/Verifier.json"
            ),
            testnetVerifier: readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/state-transition/TestnetVerifier.sol/TestnetVerifier.json"
            ),
            validatorTimelock: readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/state-transition/ValidatorTimelock.sol/ValidatorTimelock.json"
            ),
            diamondInit: readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/state-transition/chain-deps/DiamondInit.sol/DiamondInit.json"
            ),
            diamondProxy: readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/state-transition/chain-deps/DiamondProxy.sol/DiamondProxy.json"
            ),
            l1Genesis: readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/upgrades/L1GenesisUpgrade.sol/L1GenesisUpgrade.json"
            ),
            defaultUpgrade: readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/upgrades/DefaultUpgrade.sol/DefaultUpgrade.json"
            ),
            multicall3: readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/dev-contracts/Multicall3.sol/Multicall3.json"
            ),
            relayedSLDAValidator: readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/state-transition/data-availability/RelayedSLDAValidator.sol/RelayedSLDAValidator.json"
            ),
            l2LegacySharedBridge: readHardhatBytecode(
                "/../l1-contracts/artifacts-zk/contracts/bridge/L2SharedBridgeLegacy.sol/L2SharedBridgeLegacy.json"
            )
        });
    }

    function readDAContractBytecodes() internal view returns (DAContractBytecodes memory bytecodes) {
        bytecodes = DAContractBytecodes({
            rollupL1DAValidator: readFoundryBytecode(
                "/../da-contracts/out/RollupL1DAValidator.sol/RollupL1DAValidator.json"
            ),
            validiumL1DAValidator: readFoundryBytecode(
                "/../da-contracts/out/ValidiumL1DAValidator.sol/ValidiumL1DAValidator.json"
            )
        });
    }

    // add this to be excluded from coverage report
    function test() internal {}
}
