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

contract BaseUpgrade is Test {
    L2CanonicalTransaction l2CanonicalTransaction;
    ProposedUpgrade proposedUpgrade;

    function _prepereProposedUpgrade() internal {
        bytes[] memory bytesEmptyArray;
        uint256[] memory uintEmptyArray;
        uint256 protocolVersion = 1;
        uint256 chainId = 1;
        bytes memory systemContextCalldata = abi.encodeCall(ISystemContext.setChainId, (chainId));

        address verifier = makeAddr("verifier");
        bytes32 txHash = bytes32(bytes("txHash"));

        bytes memory postUpgradeCalldata = abi.encode(
            chainId,
            makeAddr("brighehub"),
            makeAddr("stateTransitionManager"),
            makeAddr("sharedBridgeAddress")
        );

        l2CanonicalTransaction = L2CanonicalTransaction({
            txType: SYSTEM_UPGRADE_L2_TX_TYPE,
            from: uint256(uint160(L2_FORCE_DEPLOYER_ADDR)),
            to: uint256(uint160(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR)),
            gasLimit: PRIORITY_TX_MAX_GAS_LIMIT,
            gasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
            maxFeePerGas: uint256(0),
            maxPriorityFeePerGas: uint256(0),
            paymaster: uint256(0),
            nonce: protocolVersion,
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
            factoryDeps: bytesEmptyArray,
            bootloaderHash: bytes32(0x01000121a363b3fbec270986067c1b553bf540c30a6f186f45313133ff1a1019),
            defaultAccountHash: bytes32(0x01000121a363b3fbec270986067c1b553bf540c30a6f186f45313133ff1a1019),
            verifier: verifier,
            verifierParams: VerifierParams({
                recursionNodeLevelVkHash: bytes32(bytes("recursionNodeLevelVkHash")),
                recursionLeafLevelVkHash: bytes32(bytes("recursionLeafLevelVkHash")),
                recursionCircuitsSetVksHash: bytes32(bytes("recursionCircuitsSetVksHash"))
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