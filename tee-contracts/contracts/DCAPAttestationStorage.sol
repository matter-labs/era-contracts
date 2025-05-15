// SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import {AutomataDaoStorage} from "@automata-network/on-chain-pccs/automata_pccs/shared/AutomataDaoStorage.sol";

/**
 * @title DCAPAttestationStorage
 * @dev A factory contract for deploying AutomataDaoStorage
 */
contract DCAPAttestationStorage {
    /**
     * @notice Creates a new AutomataDaoStorage instance
     * @return storage_ The newly created AutomataDaoStorage instance
     */
    function deployStorage() external returns (AutomataDaoStorage storage_) {
        storage_ = new AutomataDaoStorage();
    }
}