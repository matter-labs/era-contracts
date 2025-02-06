// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

import {Transaction} from "../common/l2-helpers/L2ContractHelper.sol";
import {InteropCall, InteropBundle, MessageInclusionProof, L2Message} from "../common/Messaging.sol";

interface IInteropHandler {
    function setInteropAccountBytecode() external;
    function executeBundle(bytes memory _bundle, MessageInclusionProof memory _proof, bool _skipEmptyCalldata) external;
    function getAliasedAccount(address fromAsSalt, uint256) external view returns (address);
}
