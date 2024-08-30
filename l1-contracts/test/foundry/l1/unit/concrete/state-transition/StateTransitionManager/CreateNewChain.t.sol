// // SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StateTransitionManagerTest} from "./_StateTransitionManager_Shared.t.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {Unauthorized, HashMismatch} from "contracts/common/L1ContractErrors.sol";

contract createNewChainTest is StateTransitionManagerTest {
    function test_RevertWhen_InitialDiamondCutHashMismatch() public {
        Diamond.DiamondCutData memory initialDiamondCutData = getDiamondCutData(sharedBridge);
        Diamond.DiamondCutData memory correctDiamondCutData = getDiamondCutData(address(diamondInit));

        vm.expectRevert(
            abi.encodeWithSelector(
                HashMismatch.selector,
                keccak256(abi.encode(correctDiamondCutData)),
                keccak256(abi.encode(initialDiamondCutData))
            )
        );
        createNewChain(initialDiamondCutData);
    }

    function test_RevertWhen_CalledNotByBridgehub() public {
        Diamond.DiamondCutData memory initialDiamondCutData = getDiamondCutData(diamondInit);

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, governor));
        chainContractAddress.createNewChain({
            _chainId: chainId,
            _baseTokenAssetId: DataEncoding.encodeNTVAssetId(block.chainid, baseToken),
            _sharedBridge: sharedBridge,
            _admin: admin,
            _initData: abi.encode(abi.encode(initialDiamondCutData), bytes("")),
            _factoryDeps: new bytes[](0)
        });
    }
}
