// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";

import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {L2TransactionRequestDirect} from "contracts/bridgehub/IBridgehub.sol";
import {IGovernance} from "contracts/governance/IGovernance.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA} from "contracts/common/Config.sol";
import {L2_DEPLOYER_SYSTEM_CONTRACT_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {L2ContractHelper} from "contracts/common/libraries/L2ContractHelper.sol";
import {IChainAdmin} from "contracts/governance/IChainAdmin.sol";
import {EIP712Utils} from "./EIP712Utils.sol";
import {IProtocolUpgradeHandler} from "./interfaces/IProtocolUpgradeHandler.sol";
import {IEmergencyUpgrageBoard} from "./interfaces/IEmergencyUpgrageBoard.sol";
import {IMultisig} from "./interfaces/IMultisig.sol";
import {ISafe} from "./interfaces/ISafe.sol";

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

library Utils {
    // Cheatcodes address, 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D.
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    Vm internal constant vm = Vm(VM_ADDRESS);
    // Create2Factory deterministic bytecode.
    // https://github.com/Arachnid/deterministic-deployment-proxy
    bytes internal constant CREATE2_FACTORY_BYTECODE =
        hex"604580600e600039806000f350fe7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    address constant ADDRESS_ONE = 0x0000000000000000000000000000000000000001;
    uint256 constant MAX_PRIORITY_TX_GAS = 72000000;

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
        bytes4[] memory selectors = new bytes4[](parts.length);
        for (uint256 i = 0; i < parts.length; i++) {
            bytes memory part = bytes(parts[i]);
            bytes memory extractedSelector = new bytes(10);
            // Selector length 10 is 0x + 4 bytes
            for (uint256 j = 0; j < 10; j++) {
                extractedSelector[j] = part[j];
            }
            bytes4 selector = bytes4(vm.parseBytes(string(extractedSelector)));
            selectors[i] = selector;
        }

        // Remove `getName()` selector if existing
        bool hasGetName = false;
        for (uint256 i = 0; i < selectors.length; i++) {
            if (selectors[i] == bytes4(keccak256("getName()"))) {
                selectors[i] = selectors[selectors.length - 1];
                hasGetName = true;
                break;
            }
        }
        if (hasGetName) {
            bytes4[] memory newSelectors = new bytes4[](selectors.length - 1);
            for (uint256 i = 0; i < selectors.length - 1; i++) {
                newSelectors[i] = selectors[i];
            }
            return newSelectors;
        }

        return selectors;
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
        if (bys.length < 32) {
            bytes memory padded = new bytes(32);
            for (uint256 i = 0; i < bys.length; i++) {
                padded[i + 32 - bys.length] = bys[i];
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

        bytes[] memory _factoryDeps = new bytes[](factoryDeps.length + 1);

        for (uint256 i = 0; i < factoryDeps.length; i++) {
            _factoryDeps[i] = factoryDeps[i];
        }
        _factoryDeps[factoryDeps.length] = bytecode;

        runL1L2Transaction({
            l2Calldata: deployData,
            l2GasLimit: l2GasLimit,
            factoryDeps: _factoryDeps,
            dstAddress: L2_DEPLOYER_SYSTEM_CONTRACT_ADDR,
            chainId: chainId,
            bridgehubAddress: bridgehubAddress,
            l1SharedBridgeProxy: l1SharedBridgeProxy
        });
        return contractAddress;
    }

    /**
     * @dev Run the l2 l1 transaction
     */
    function runL1L2Transaction(
        bytes memory l2Calldata,
        uint256 l2GasLimit,
        bytes[] memory factoryDeps,
        address dstAddress,
        uint256 chainId,
        address bridgehubAddress,
        address l1SharedBridgeProxy
    ) internal {
        Bridgehub bridgehub = Bridgehub(bridgehubAddress);
        uint256 gasPrice = bytesToUint256(vm.rpc("eth_gasPrice", "[]"));

        uint256 requiredValueToDeploy = bridgehub.l2TransactionBaseCost(
            chainId,
            gasPrice,
            l2GasLimit,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA
        ) * 2;

        L2TransactionRequestDirect memory l2TransactionRequestDirect = L2TransactionRequestDirect({
            chainId: chainId,
            mintValue: requiredValueToDeploy,
            l2Contract: dstAddress,
            l2Value: 0,
            l2Calldata: l2Calldata,
            l2GasLimit: l2GasLimit,
            l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            factoryDeps: factoryDeps,
            refundRecipient: msg.sender
        });

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
            factoryDeps: factoryDeps,
            dstAddress: 0x0000000000000000000000000000000000000000,
            chainId: chainId,
            bridgehubAddress: bridgehubAddress,
            l1SharedBridgeProxy: l1SharedBridgeProxy
        });
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

    function chainAdminMulticall(address _chainAdmin, address _target, bytes memory _data, uint256 _value) internal {
        IChainAdmin chainAdmin = IChainAdmin(_chainAdmin);

        IChainAdmin.Call[] memory calls = new IChainAdmin.Call[](1);
        calls[0] = IChainAdmin.Call({target: _target, value: _value, data: _data});
        vm.broadcast();
        chainAdmin.multicall(calls, true);
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

        IGovernance.Call[] memory calls = new IGovernance.Call[](1);
        calls[0] = IGovernance.Call({target: _target, value: _value, data: _data});

        IGovernance.Operation memory operation = IGovernance.Operation({
            calls: calls,
            predecessor: bytes32(0),
            salt: _salt
        });

        vm.startBroadcast();
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
}
