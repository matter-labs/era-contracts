// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Script, console2 as console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {IZkSyncHyperchain} from "contracts/state-transition/chain-interfaces/IZkSyncHyperchain.sol";
import {PubdataPricingMode} from "contracts/state-transition/chain-deps/ZkSyncHyperchainStorage.sol";
import {StateTransitionManager} from "contracts/state-transition/StateTransitionManager.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";

contract ChainConfigurationReader is Script {
    function run(address stmAddress, uint256 chainId) public {
        StateTransitionManager stm = StateTransitionManager(stmAddress);
        IZkSyncHyperchain diamondProxy = IZkSyncHyperchain(stm.getHyperchain(chainId));
        address payable chainAdmin = payable(stm.getChainAdmin(chainId));
        address tokenMultiplierSetter = ChainAdmin(chainAdmin).tokenMultiplierSetter();
        address owner = ChainAdmin(chainAdmin).owner();
        address basetoken = diamondProxy.getBaseToken();
        (uint32 major, uint32 minor, uint32 patch) = diamondProxy.getSemverProtocolVersion();
        address validatorTimelock = stm.validatorTimelock();
        PubdataPricingMode pubdataPricingMode = diamondProxy.getPubdataPricingMode();

        uint256 baseTokenGasPriceMultiplierNominator = diamondProxy.baseTokenGasPriceMultiplierNominator();
        uint256 baseTokenGasPriceMultiplierDenominator = diamondProxy.baseTokenGasPriceMultiplierDenominator();

        if (pubdataPricingMode == PubdataPricingMode.Validium) {} else if (
            pubdataPricingMode == PubdataPricingMode.Rollup
        ) {}

        getNewValidators(validatorTimelock, chainId);
    }

    function getNewValidators(address validatorTimelock, uint256 chainId) internal {
        bytes32[] memory topics = new bytes32[](2);
        topics[0] = ValidatorTimelock.ValidatorAdded.selector;
        topics[1] = bytes32(chainId);
        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(1, block.number, validatorTimelock, topics);
        for (uint256 i = 0; i < logs.length; i++) {
            Vm.EthGetLogs memory log = logs[i];
        }
    }

    function bytesToAddress(bytes memory bys) private pure returns (address addr) {
        assembly {
            addr := mload(add(bys, 32))
        }
    }
}
