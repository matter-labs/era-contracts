// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ChainTypeManagerTest} from "./_ChainTypeManager_Shared.t.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {HashMismatch, Unauthorized, ZKChainLimitReached, ZeroAddress} from "contracts/common/L1ContractErrors.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {EraChainTypeManager} from "contracts/state-transition/EraChainTypeManager.sol";

import {IL1Bridgehub} from "contracts/bridgehub/IL1Bridgehub.sol";
import {IBridgehubBase} from "contracts/bridgehub/IBridgehubBase.sol";

contract createNewChainTest is ChainTypeManagerTest {
    function setUp() public {
        deploy();
    }

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
            _admin: admin,
            _initData: abi.encode(abi.encode(initialDiamondCutData), bytes("")),
            _factoryDeps: new bytes[](0)
        });
    }

    function test_SuccessfulCreationOfNewChain() public {
        address newChainAddress = createNewChain(getDiamondCutData(diamondInit));

        address admin = IZKChain(newChainAddress).getAdmin();

        assertEq(newChainAdmin, admin);
        assertNotEq(newChainAddress, address(0));
    }

    function test_SuccessfulCreationOfNewChainAndReturnChainId() public {
        createNewChain(getDiamondCutData(diamondInit));

        uint256[] memory mockData = new uint256[](1);
        mockData[0] = chainId;

        vm.mockCall(address(bridgehub), abi.encodeCall(IBridgehubBase.getAllZKChainChainIDs, ()), abi.encode(mockData));
        uint256[] memory chainIds = _getAllZKChainIDs();

        assertEq(chainIds.length, 1);
        assertEq(chainIds[0], chainId);
    }
}
