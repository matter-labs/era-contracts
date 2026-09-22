// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {
    PRIORITY_TX_MAX_GAS_LIMIT,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
    ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE
} from "contracts/common/Config.sol";
import {
    L2_FORCE_DEPLOYER_ADDR,
    L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {ISystemContext} from "contracts/common/interfaces/ISystemContext.sol";
import {ZKSyncOSBytecodeInfo} from "contracts/common/libraries/ZKSyncOSBytecodeInfo.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";

/// @notice The hand-built inputs of the shared storage part (`BaseZkSyncUpgrade._upgrade`):
///         a well-formed L2 upgrade transaction, the version it moves to, its schedule and verifier.
contract BaseUpgrade is Test {
    L2CanonicalTransaction l2CanonicalTransaction;

    /// @dev The version the prepared upgrade moves to.
    uint256 public protocolVersion;
    uint256 public upgradeTimestamp;
    address public verifier;
    uint256 public chainId;

    function _prepareUpgrade() internal {
        bytes[] memory bytesEmptyArray = new bytes[](1);
        bytesEmptyArray[0] = "11111111111111111111111111111111";
        uint256[] memory uintEmptyArray = new uint256[](1);
        uintEmptyArray[0] = uint256(ZKSyncOSBytecodeInfo.hashEVMBytecode(bytesEmptyArray[0]));

        protocolVersion = SemVer.packSemVer(0, 1, 0);
        upgradeTimestamp = 0;
        chainId = 1;
        bytes memory systemContextCalldata = abi.encodeCall(ISystemContext.setSettlementLayerChainId, (chainId));

        verifier = makeAddr("verifier");

        l2CanonicalTransaction = L2CanonicalTransaction({
            txType: ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE,
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
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
