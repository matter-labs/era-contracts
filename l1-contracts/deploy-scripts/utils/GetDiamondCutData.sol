// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {Script} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {ChainTypeManagerBase} from "contracts/state-transition/ChainTypeManagerBase.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

library GetDiamondCutData {
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    Vm internal constant vm = Vm(VM_ADDRESS);

    /// @notice Fetches the diamond cut data by reading the on-chain log for the given protocol version.
    /// @dev This keeps the existing behavior for live scripts where `eth_getLogs` is available.
    function getDiamondCutData(
        address ctm,
        uint256 protocolVersion
    ) external returns (Diamond.DiamondCutData memory diamondCutData) {
        ChainTypeManagerBase chainTypeManager = ChainTypeManagerBase(ctm);
        uint256 blockWithData = chainTypeManager.upgradeCutDataBlock(protocolVersion);
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = IChainTypeManager.NewUpgradeCutData.selector;
        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(blockWithData, blockWithData, ctm, topics);
        require(logs.length > 0, "No logs found for NewUpgradeCutData");
        // Assuming the first log is the one we want
        bytes memory data = logs[0].data;
        diamondCutData = abi.decode(data, (Diamond.DiamondCutData));
    }

    /// @notice Parse diamond cut data from already-recorded logs (e.g. in tests).
    function getDiamondCutDataFromRecordedLogs(
        Vm.Log[] memory logs,
        address ctm
    ) internal pure returns (Diamond.DiamondCutData memory diamondCutData) {
        // TODO check the block number
        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory logEntry = logs[i];
            if (
                logEntry.emitter == ctm &&
                logEntry.topics.length > 0 &&
                logEntry.topics[0] == IChainTypeManager.NewUpgradeCutData.selector
            ) {
                diamondCutData = abi.decode(logEntry.data, (Diamond.DiamondCutData));
                return diamondCutData;
            }
        }
        revert("No recorded logs for NewUpgradeCutData");
    }
}
