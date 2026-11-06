// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ContractsBytecodesLib} from "../../utils/bytecode/ContractsBytecodesLib.sol";

/// @title Release-member code probe.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Answers "what runtime code would this prepare deploy for `_name`?" — the question a
///         prepare must settle before it can reuse a live release member instead of replacing it.
/// @dev A separate CONTRACT, not a helper on the script, for two reasons. Reading a build artifact
///      leaves the whole JSON in the reading frame's memory, memory is charged quadratically, and a
///      prepare reads dozens of artifacts — doing it in the pipeline's own frame is enough to run a
///      prepare out of gas. And a forge script may not call itself: `this.f()` is a use of
///      `address(this)`, which forge refuses in script contracts. So the read and the probe
///      deployment happen here, in a frame that is discarded on return.
/// @dev The probe deployment is a plain CREATE and is never broadcast, so it exists only inside the
///      run's own simulation. Creation code is resolved through the same
///      {ContractsBytecodesLib.getCreationCodeEVM} every `deploySimpleContract` uses, so the answer
///      describes what the prepare would actually deploy.
contract ReleaseMemberProbe {
    /// @notice The runtime codehash `_name` gets when deployed from the current build artifacts
    ///         with `_constructorArgs` — immutables included, which is why this deploys rather than
    ///         hashing the artifact (an artifact's `deployedBytecode` has its immutable slots
    ///         zeroed).
    function codehashOf(string memory _name, bytes memory _constructorArgs) external returns (bytes32) {
        bytes memory initCode = abi.encodePacked(ContractsBytecodesLib.getCreationCodeEVM(_name), _constructorArgs);
        address probe;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            probe := create(0, add(initCode, 0x20), mload(initCode))
        }
        // solhint-disable-next-line gas-custom-errors
        require(probe != address(0), "release member code probe failed to deploy");
        return probe.codehash;
    }
}
