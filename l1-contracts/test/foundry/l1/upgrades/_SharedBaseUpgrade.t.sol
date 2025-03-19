// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProposedUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {VerifierParams} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {SYSTEM_UPGRADE_L2_TX_TYPE} from "contracts/common/Config.sol";
import {L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR, L2_FORCE_DEPLOYER_ADDR} from "contracts/common/L2ContractAddresses.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA, SYSTEM_UPGRADE_L2_TX_TYPE, PRIORITY_TX_MAX_GAS_LIMIT} from "contracts/common/Config.sol";
import {ISystemContext} from "contracts/state-transition/l2-deps/ISystemContext.sol";
import {L2ContractHelper} from "contracts/common/libraries/L2ContractHelper.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";

contract BaseUpgrade is Test {
    L2CanonicalTransaction l2CanonicalTransaction;
    ProposedUpgrade proposedUpgrade;

    uint256 public protocolVersion;
    uint256 public chainId;

    address public bridgeHub;
    address public stateTransitionManager;
    address public sharedBridge;

    address verifier;

    function _prepareProposedUpgrade() internal {
        bytes[] memory bytesEmptyArray = new bytes[](1);
        bytesEmptyArray[0] = "11111111111111111111111111111111";
        uint256[] memory uintEmptyArray = new uint256[](1);
        uintEmptyArray[0] = uint256(L2ContractHelper.hashL2Bytecode(bytesEmptyArray[0]));

        protocolVersion = SemVer.packSemVer(0, 1, 0);
        chainId = 1;
        bytes memory systemContextCalldata = abi.encodeCall(ISystemContext.setChainId, (chainId));

        verifier = makeAddr("verifier");
        bytes32 txHash = bytes32(bytes("txHash"));

        bridgeHub = makeAddr("brigheHub");
        stateTransitionManager = makeAddr("stateTransitionManager");
        sharedBridge = makeAddr("sharedBridge");

        bytes memory postUpgradeCalldata = abi.encode(chainId, bridgeHub, stateTransitionManager, sharedBridge);

        l2CanonicalTransaction = L2CanonicalTransaction({
            txType: SYSTEM_UPGRADE_L2_TX_TYPE,
            from: uint256(uint160(L2_FORCE_DEPLOYER_ADDR)),
            to: uint256(uint160(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR)),
            gasLimit: PRIORITY_TX_MAX_GAS_LIMIT,
            gasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            maxFeePerGas: uint256(0),
            maxPriorityFeePerGas: uint256(0),
            paymaster: uint256(0),
            nonce: 1,
            value: 0,
            reserved: [uint256(0), 0, 0, 0],
            data: systemContextCalldata,
            signature: new bytes(0),
            factoryDeps: uintEmptyArray,
            paymasterInput: new bytes(0),
            reservedDynamic: new bytes(0)
        });

        proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: l2CanonicalTransaction,
            bootloaderHash: bytes32(0x01000121a363b3fbec270986067c1b553bf540c30a6f186f45313133ff1a1019),
            defaultAccountHash: bytes32(0x01000121a363b3fbec270986067c1b553bf540c30a6f186f45313133ff1a1019),
            evmEmulatorHash: bytes32(0x01000121a363b3fbec270986067c1b553bf540c30a6f186f45313133ff1a1019),
            verifier: verifier,
            verifierParams: VerifierParams({
                recursionNodeLevelVkHash: bytes32(0),
                recursionLeafLevelVkHash: bytes32(0),
                recursionCircuitsSetVksHash: bytes32(0)
            }),
            l1ContractsUpgradeCalldata: new bytes(0),
            postUpgradeCalldata: postUpgradeCalldata,
            upgradeTimestamp: 0,
            newProtocolVersion: protocolVersion
        });
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
