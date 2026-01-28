// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {stdJson} from "forge-std/StdJson.sol";
import {Vm} from "forge-std/Vm.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {ChainCreationParamsConfig} from "../utils/Types.sol";

library ChainCreationParamsLib {
    using stdJson for string;
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    Vm internal constant vm = Vm(VM_ADDRESS);

    function getChainCreationParams(
        string memory _config,
        bool isZKsyncOs
    ) public returns (ChainCreationParamsConfig memory chainCreationParams) {
        string memory json = vm.readFile(_config);
        uint32 major = uint32(json.readUint("$.protocol_semantic_version.major"));
        uint32 minor = uint32(json.readUint("$.protocol_semantic_version.minor"));
        uint32 patch = uint32(json.readUint("$.protocol_semantic_version.patch"));
        chainCreationParams.latestProtocolVersion = SemVer.packSemVer(major, minor, patch);
        chainCreationParams.genesisRoot = json.readBytes32("$.genesis_root");
        if (isZKsyncOs) {
            chainCreationParams.genesisBatchCommitment = bytes32(uint256(1));
        } else {
            // These fields are used only for zksync era
            chainCreationParams.genesisRollupLeafIndex = json.readUint("$.genesis_rollup_leaf_index");
            chainCreationParams.genesisBatchCommitment = json.readBytes32("$.genesis_batch_commitment");
            chainCreationParams.defaultAAHash = json.readBytes32("$.default_aa_hash");
            chainCreationParams.bootloaderHash = json.readBytes32("$.bootloader_hash");
            chainCreationParams.evmEmulatorHash = json.readBytes32("$.evm_emulator_hash");
        }
    }
}
