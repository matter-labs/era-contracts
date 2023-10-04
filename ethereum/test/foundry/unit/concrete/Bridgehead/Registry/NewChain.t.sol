// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

/* solhint-disable max-line-length */

import {RegistryTest} from "./_Registry_Shared.t.sol";
import {IAllowList} from "../../../../../../cache/solpp-generated-contracts/common/interfaces/IAllowList.sol";
import {AllowList} from "../../../../../../cache/solpp-generated-contracts/common/AllowList.sol";
import {Diamond} from "../../../../../../cache/solpp-generated-contracts/common/libraries/Diamond.sol";
import {IProofSystem} from "../../../../../../cache/solpp-generated-contracts/proof-system/proof-system-interfaces/IProofSystem.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IBridgeheadChain} from "../../../../../../cache/solpp-generated-contracts/bridgehead/chain-interfaces/IBridgeheadChain.sol";
import {Vm} from "forge-std/Test.sol";
import {IRegistry} from "../../../../../../cache/solpp-generated-contracts/bridgehead/bridgehead-interfaces/IRegistry.sol";

/* solhint-enable max-line-length */

contract NewChainTest is RegistryTest {
    uint256 internal chainId;
    address internal governorAddress;
    IAllowList internal allowList;

    function setUp() public {
        chainId = 838383838383;
        proofSystemAddress = makeAddr("chainProofSystemAddress");
        governorAddress = makeAddr("governorAddress");
        allowList = new AllowList(governorAddress);

        vm.prank(GOVERNOR);
        bridgehead.newProofSystem(proofSystemAddress);
    }

    function getChainContractAddress() internal returns (address chainContractAddress) {
        vm.mockCall(
            bridgehead.getChainImplementation(),
            abi.encodeWithSelector(IBridgeheadChain.initialize.selector),
            ""
        );

        uint256 snapshot = vm.snapshot();
        vm.startPrank(address(bridgehead));

        bytes memory data = abi.encodeWithSelector(
            IBridgeheadChain.initialize.selector,
            chainId,
            proofSystemAddress,
            governorAddress,
            allowList,
            bridgehead.getPriorityTxMaxGasLimit()
        );
        TransparentUpgradeableProxy transparentUpgradeableProxy = new TransparentUpgradeableProxy(
            bridgehead.getChainImplementation(),
            bridgehead.getChainProxyAdmin(),
            data
        );
        chainContractAddress = address(transparentUpgradeableProxy);

        vm.stopPrank();
        vm.revertTo(snapshot);
    }

    function test_RevertWhen_NonGovernor() public {
        vm.startPrank(NON_GOVERNOR);
        vm.expectRevert(bytes.concat("12g"));
        bridgehead.newChain(chainId, proofSystemAddress, governorAddress, allowList, getDiamondCutData());
    }

    function test_RevertWhen_ProofSystemIsNotInStorage() public {
        address nonExistentProofSystemAddress = address(0x3030303);

        vm.startPrank(GOVERNOR);
        vm.expectRevert(bytes.concat("r19"));
        bridgehead.newChain(chainId, nonExistentProofSystemAddress, governorAddress, allowList, getDiamondCutData());
    }

    function test_RevertWhen_ChainIdIsAlreadyInUse() public {
        vm.mockCall(
            bridgehead.getChainImplementation(),
            abi.encodeWithSelector(IBridgeheadChain.initialize.selector),
            ""
        );
        vm.mockCall(proofSystemAddress, abi.encodeWithSelector(IProofSystem.newChain.selector), "");

        vm.startPrank(GOVERNOR);
        bridgehead.newChain(chainId, proofSystemAddress, governorAddress, allowList, getDiamondCutData());

        vm.expectRevert(bytes.concat("r20"));
        bridgehead.newChain(chainId, proofSystemAddress, governorAddress, allowList, getDiamondCutData());
    }

    function test_NewChainSuccessfullyWithNonZeroChainId() public {
        // === Shared variables ===
        address chainContractAddress = getChainContractAddress();

        // === Mocking ===
        vm.mockCall(
            bridgehead.getChainImplementation(),
            abi.encodeWithSelector(IBridgeheadChain.initialize.selector),
            ""
        );
        vm.mockCall(proofSystemAddress, abi.encodeWithSelector(IProofSystem.newChain.selector), "");

        // === Internal call checks ===
        vm.expectCall(
            bridgehead.getChainImplementation(),
            abi.encodeWithSelector(
                IBridgeheadChain.initialize.selector,
                chainId,
                proofSystemAddress,
                governorAddress,
                allowList,
                bridgehead.getPriorityTxMaxGasLimit()
            ),
            1
        );
        vm.expectCall(
            proofSystemAddress,
            abi.encodeWithSelector(
                IProofSystem.newChain.selector,
                chainId,
                chainContractAddress,
                governorAddress,
                getDiamondCutData()
            ),
            1
        );

        // === Function call ===
        vm.recordLogs();
        vm.startPrank(GOVERNOR);

        uint256 resChainId = bridgehead.newChain(
            chainId,
            proofSystemAddress,
            governorAddress,
            allowList,
            getDiamondCutData()
        );

        vm.stopPrank();
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // === Emitted event checks ===
        assertEq(entries[2].topics[0], IRegistry.NewChain.selector, "NewChain event not emitted");
        assertEq(entries[2].topics.length, 4, "NewChain event should have 4 topics");

        uint16 eventChainId = abi.decode(abi.encode(entries[2].topics[1]), (uint16));
        address eventChainContract = abi.decode(abi.encode(entries[2].topics[2]), (address));
        address eventChainGovernnance = abi.decode(abi.encode(entries[2].topics[3]), (address));
        address eventProofSystem = abi.decode(entries[2].data, (address));

        assertEq(eventChainId, uint16(chainId), "NewChain.chainId is wrong");
        assertEq(eventChainContract, chainContractAddress, "NewChain.chainContract is wrong");
        assertEq(eventChainGovernnance, GOVERNOR, "NewChain.chainGovernance is wrong");
        assertEq(eventProofSystem, proofSystemAddress, "NewChain.proofSystem is wrong");

        // === Storage checks ===
        assertEq(bridgehead.getChainProofSystem(chainId), proofSystemAddress, "saved chainProofSystem is wrong");
        assertEq(bridgehead.getTotalChains(), 1, "saved totalChains is wrong");
        assertEq(bridgehead.getChainContract(chainId), chainContractAddress, "saved chainContract address is wrong");
        assertEq(resChainId, chainId, "returned chainId is wrong");
    }

    function test_NewChainSuccessfullyWithZeroChainId() public {
        // === Shared variables ===
        address chainContractAddress = getChainContractAddress();
        uint256 inputChainId = 0;
        chainId = uint16(
            uint256(
                keccak256(
                    abi.encodePacked(
                        "CHAIN_ID",
                        block.chainid,
                        address(bridgehead),
                        proofSystemAddress,
                        block.timestamp,
                        GOVERNOR
                    )
                )
            )
        );

        // === Mocking ===
        vm.mockCall(
            bridgehead.getChainImplementation(),
            abi.encodeWithSelector(IBridgeheadChain.initialize.selector),
            ""
        );
        vm.mockCall(proofSystemAddress, abi.encodeWithSelector(IProofSystem.newChain.selector), "");

        // === Internal call checks ===
        vm.expectCall(
            bridgehead.getChainImplementation(),
            abi.encodeWithSelector(
                IBridgeheadChain.initialize.selector,
                chainId,
                proofSystemAddress,
                governorAddress,
                allowList,
                bridgehead.getPriorityTxMaxGasLimit()
            ),
            1
        );
        vm.expectCall(
            proofSystemAddress,
            abi.encodeWithSelector(
                IProofSystem.newChain.selector,
                chainId,
                chainContractAddress,
                governorAddress,
                getDiamondCutData()
            ),
            1
        );

        // === Function call ===
        vm.recordLogs();
        vm.startPrank(GOVERNOR);

        uint256 resChainId = bridgehead.newChain(
            inputChainId,
            proofSystemAddress,
            governorAddress,
            allowList,
            getDiamondCutData()
        );

        vm.stopPrank();
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // === Emitted event checks ===
        assertEq(entries[2].topics[0], IRegistry.NewChain.selector, "NewChain event not emitted");
        assertEq(entries[2].topics.length, 4, "NewChain event should have 4 topics");

        uint16 eventChainId = abi.decode(abi.encode(entries[2].topics[1]), (uint16));
        address eventChainContract = abi.decode(abi.encode(entries[2].topics[2]), (address));
        address eventChainGovernnance = abi.decode(abi.encode(entries[2].topics[3]), (address));
        address eventProofSystem = abi.decode(entries[2].data, (address));

        assertEq(eventChainId, uint16(chainId), "NewChain.chainId is wrong");
        assertEq(eventChainContract, chainContractAddress, "NewChain.chainContract is wrong");
        assertEq(eventChainGovernnance, GOVERNOR, "NewChain.chainGovernance is wrong");
        assertEq(eventProofSystem, proofSystemAddress, "NewChain.proofSystem is wrong");

        // === Storage checks ===
        assertEq(bridgehead.getChainProofSystem(chainId), proofSystemAddress, "saved chainProofSystem is wrong");
        assertEq(bridgehead.getTotalChains(), 1, "saved totalChains is wrong");
        assertEq(bridgehead.getChainContract(chainId), chainContractAddress, "saved chainContract address is wrong");
        assertEq(resChainId, chainId, "returned chainId is wrong");
    }
}
