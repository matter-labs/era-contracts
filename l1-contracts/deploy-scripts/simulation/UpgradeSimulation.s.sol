// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {Call} from "contracts/governance/Common.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {ChainTypeManagerBase} from "contracts/state-transition/ChainTypeManagerBase.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {AddressIntrospector} from "deploy-scripts/utils/AddressIntrospector.sol";
import {ZkChainAddresses} from "deploy-scripts/utils/Types.sol";
import {UpgradeChainCall} from "deploy-scripts/utils/UpgradeChainCall.sol";
import {ZKSYNC_OS_TEST_CREATE_CHAIN_ID} from "./Constants.sol";

/// @notice Adds chain-upgrade and chain-creation probes to a prepared package for simulator replay.
/// @dev Runs separately after production prepare, on the same fork, without broadcasting calls.
// solhint-disable gas-custom-errors
contract UpgradeSimulation is Script {
    using stdToml for string;

    function run() external {
        address ctm = vm.envAddress("UPGRADE_SIMULATION_CTM");
        string memory outputPath = vm.envString("UPGRADE_SIMULATION_OUTPUT");
        string memory output = vm.readFile(outputPath);
        require(!output.keyExists(".test_upgrade_calls"), "simulation calls already exist; rerun prepare first");
        Diamond.DiamondCutData memory cut = abi.decode(
            output.readBytes(".chain_upgrade_diamond_cut"),
            (Diamond.DiamondCutData)
        );
        ZkChainAddresses memory witness = AddressIntrospector.getUptoDateZkChainAddresses(ChainTypeManagerBase(ctm));
        Call[] memory upgradeCalls = new Call[](1);
        upgradeCalls[0] = Call({
            target: witness.zkChainProxy,
            value: 0,
            data: UpgradeChainCall.encode(witness.zkChainProxy, ChainTypeManagerBase(ctm).protocolVersion(), cut)
        });
        Call[] memory createCalls = new Call[](1);
        createCalls[0] = createChainCall(ctm, witness.chainId, ZKSYNC_OS_TEST_CREATE_CHAIN_ID, msg.sender);
        address bridgehub = ChainTypeManagerBase(ctm).BRIDGE_HUB();
        // Append an independent table; keyed writeToml would replace the rest of the package.
        vm.writeLine(
            outputPath,
            string.concat(
                "\n[test_upgrade_calls]\n",
                'test_upgrade_chain = "',
                vm.toString(abi.encode(upgradeCalls)),
                '"\n',
                'test_upgrade_chain_caller = "',
                vm.toString(IZKChain(witness.zkChainProxy).getAdmin()),
                '"\n',
                'test_create_chain = "',
                vm.toString(abi.encode(createCalls)),
                '"\n',
                'test_create_chain_caller = "',
                vm.toString(IL1Bridgehub(bridgehub).admin()),
                '"\n'
            )
        );
    }

    function createChainCall(
        address _ctm,
        uint256 _witnessChainId,
        uint256 _newChainId,
        address _newChainAdmin
    ) public view returns (Call memory) {
        IL1Bridgehub bridgehub = IL1Bridgehub(ChainTypeManagerBase(_ctm).BRIDGE_HUB());
        return
            Call({
                target: address(bridgehub),
                value: 0,
                data: abi.encodeCall(
                    IL1Bridgehub.createNewChain,
                    (_newChainId, _ctm, bridgehub.baseTokenAssetId(_witnessChainId), _newChainAdmin)
                )
            });
    }
}
