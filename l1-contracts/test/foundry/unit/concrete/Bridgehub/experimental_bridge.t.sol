//SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.20;

import {stdStorage, StdStorage, Test} from "forge-std/Test.sol";           



import {Diamond} from "solpp/state-transition/libraries/Diamond.sol";
import {TestnetERC20Token} from "solpp/dev-contracts/TestnetERC20Token.sol";
import {IBridgehub, Bridgehub} from "solpp/bridgehub/Bridgehub.sol";
import {DummyStateTransitionManagerWBH} from "solpp/dev-contracts/test/DummyStateTransitionManagerWithBridgeHubAddress.sol";
import {DummyStateTransition} from "solpp/dev-contracts/test/DummyStateTransition.sol";
import {IL1SharedBridge} from "solpp/bridge/interfaces/IL1SharedBridge.sol";

import {L2Message, L2Log, TxStatus} from "solpp/common/Messaging.sol";

contract ExperimentalBridgeTest is Test {
    using stdStorage for StdStorage;

    Bridgehub bridgeHub;
    address public bridgeOwner;
    DummyStateTransitionManagerWBH mockSTM;
    DummyStateTransition mockChainContract;
    TestnetERC20Token testToken;

    function setUp() public {
        bridgeHub = new Bridgehub();
        bridgeOwner = makeAddr("BRIDGE_OWNER");
        mockSTM = new DummyStateTransitionManagerWBH(address(bridgeHub));
        mockChainContract = new DummyStateTransition();
        testToken = new TestnetERC20Token("ZKSTT", "ZkSync Test Token", 18);

        // test if the ownership of the bridgeHub is set correctly or not
        address defaultOwner = bridgeHub.owner();

        // The defaultOwner should be the same as this contract address, since this is the one deploying the bridgehub contract
        assertEq(defaultOwner, address(this));

        // Now, the `reentrancyGuardInitializer` should prevent anyone from calling `initialize` since we have called the constructor of the contract
        // @follow-up Is this the intended behavior? @Vlad @kalman
        vm.expectRevert(bytes("1B"));
        bridgeHub.initialize(bridgeOwner);

        // The ownership can only be transfered by the current owner to a new owner via the two-step approach
        
        // Default owner calls transferOwnership
        bridgeHub.transferOwnership(bridgeOwner);

        // bridgeOwner calls acceptOwnership
        vm.prank(bridgeOwner);
        bridgeHub.acceptOwnership();

        // Ownership should have changed
        assertEq(bridgeHub.owner(), bridgeOwner);
    }

    function test_ownerCanSetDeployer(address randomCaller, address randomDeployer) public {
        /**
            Case I: A random address tries to call the `setDeployer` method and the call fails with the error: `Ownable: caller is not the owner`
            Case II: The bridgeHub owner calls the `setDeployer` method on `randomDeployer` and it becomes the deployer
        */
        
        if(randomCaller != bridgeHub.owner()) {
            vm.prank(randomCaller);
            vm.expectRevert(bytes("Ownable: caller is not the owner"));
            bridgeHub.setDeployer(randomDeployer);

            // The deployer shouldn't have changed.
            assertEq(address(0), bridgeHub.deployer());
        } else { 
            vm.prank(randomCaller);
            bridgeHub.setDeployer(randomDeployer);

            assertEq(randomDeployer, bridgeHub.deployer());
        }
    }

    // @follow-up Concern:
    // 1. Addresses that do not implement the correct interface or any interface whatsoever (EOAs and address(0)) can also be added as a StateTransitionManager
    // 2. After being added, if the contracts are upgradable, they can change their logic to include malicious code as well.
    function test_addStateTransitionManager(address randomAddressWithoutTheCorrectInterface, address randomCaller) public {
        bool isSTMRegistered = bridgeHub.stateTransitionManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(!isSTMRegistered);

        if(randomCaller != bridgeOwner) {
            vm.prank(randomCaller);
            vm.expectRevert(bytes("Ownable: caller is not the owner"));
            
            bridgeHub.addStateTransitionManager(randomAddressWithoutTheCorrectInterface);
        }
        
        vm.prank(bridgeOwner);
        bridgeHub.addStateTransitionManager(randomAddressWithoutTheCorrectInterface);
        
        isSTMRegistered = bridgeHub.stateTransitionManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(isSTMRegistered);

        // An address that has already been registered, cannot be registered again (atleast not before calling `removeStateTransitionManager`).
        vm.prank(bridgeOwner);
        vm.expectRevert(bytes("Bridgehub: state transition already registered"));
        bridgeHub.addStateTransitionManager(randomAddressWithoutTheCorrectInterface);

        isSTMRegistered = bridgeHub.stateTransitionManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(isSTMRegistered);
    }

    function test_removeStateTransitionManager(address randomAddressWithoutTheCorrectInterface, address randomCaller) public {
        bool isSTMRegistered = bridgeHub.stateTransitionManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(!isSTMRegistered);

        if(randomCaller != bridgeOwner) {
            vm.prank(randomCaller);
            vm.expectRevert(bytes("Ownable: caller is not the owner"));
            
            bridgeHub.removeStateTransitionManager(randomAddressWithoutTheCorrectInterface);
        } 
        
        // A non-existent STM cannot be removed
        vm.prank(bridgeOwner);
        vm.expectRevert(bytes("Bridgehub: state transition not registered yet"));
        bridgeHub.removeStateTransitionManager(randomAddressWithoutTheCorrectInterface);
        
        // Let's first register our particular stateTransitionManager
        vm.prank(bridgeOwner);
        bridgeHub.addStateTransitionManager(randomAddressWithoutTheCorrectInterface);
        
        isSTMRegistered = bridgeHub.stateTransitionManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(isSTMRegistered);

        // Only an address that has already been registered, can be removed.
        vm.prank(bridgeOwner);
        bridgeHub.removeStateTransitionManager(randomAddressWithoutTheCorrectInterface);

        isSTMRegistered = bridgeHub.stateTransitionManagerIsRegistered(randomAddressWithoutTheCorrectInterface);
        assertTrue(!isSTMRegistered);

        // An already removed STM cannot be removed again
        vm.prank(bridgeOwner);
        vm.expectRevert(bytes("Bridgehub: state transition not registered yet"));
        bridgeHub.removeStateTransitionManager(randomAddressWithoutTheCorrectInterface);
    }

    function test_addToken(address randomCaller, address randomAddress) public {
        if(randomCaller != bridgeOwner) {
            vm.prank(randomCaller);
            vm.expectRevert(bytes("Ownable: caller is not the owner"));
            bridgeHub.addToken(randomAddress);
        }

        assertTrue(!bridgeHub.tokenIsRegistered(randomAddress), "This random address is not registered as a token");

        vm.prank(bridgeOwner);
        bridgeHub.addToken(randomAddress);

        assertTrue(bridgeHub.tokenIsRegistered(randomAddress), "after call from the bridgeowner, this randomAddress should be a registered token");
        
        if(randomAddress != address(testToken)) {
            // Testing to see if an actual ERC20 implementation can also be added or not
            vm.prank(bridgeOwner);
            bridgeHub.addToken(address(testToken));

            assertTrue(bridgeHub.tokenIsRegistered(address(testToken)));
        }
    }

    function test_setSharedBridge(address randomCaller, address randomAddress) public {
        if(randomCaller != bridgeOwner) {
            vm.prank(randomCaller);
            vm.expectRevert(bytes("Ownable: caller is not the owner"));
            bridgeHub.setSharedBridge(randomAddress);
        }

        assertTrue(bridgeHub.sharedBridge() == IL1SharedBridge(address(0)), "This random address is not registered as sharedBridge");

        vm.prank(bridgeOwner);
        bridgeHub.setSharedBridge(randomAddress);

        assertTrue(bridgeHub.sharedBridge() == IL1SharedBridge(randomAddress), "after call from the bridgeowner, this randomAddress should be the registered sharedBridge");
    }


/*
    uint256 newChainId;
    address admin;
    function test_createNewChain(
        address randomCaller, 
        uint256 chainId,
        bool isFreezable, 
        bytes4[] memory mockSelectors, 
        address mockInitAddress, 
        bytes memory mockInitCalldata
    ) public {
        address deployerAddress = makeAddr("DEPLOYER_ADDRESS");
        address mockSharedBridge = makeAddr("MOCK_SHARED_BRIDGE");
        admin = makeAddr("NEW_CHAIN_ADMIN");
        Diamond.DiamondCutData memory dcData;

        vm.startPrank(bridgeOwner);
        bridgeHub.setDeployer(deployerAddress);
        bridgeHub.addStateTransitionManager(address(mockSTM));
        bridgeHub.addToken(address(testToken));
        bridgeHub.setSharedBridge(mockSharedBridge);
        vm.stopPrank();

        if(randomCaller != deployerAddress && randomCaller != bridgeOwner) {
            vm.prank(randomCaller);
            vm.expectRevert(bytes("Bridgehub: not owner or deployer"));
            bridgeHub.createNewChain(
                chainId,
                address(mockSTM),
                address(testToken),
                uint256(123),
                admin,
                bytes("")
            );
        }

        chainId = bound(chainId, 1, type(uint48).max);
        bytes memory _newChainInitData = _createNewChainInitData(isFreezable, mockSelectors, mockInitAddress, mockInitCalldata);

        emit log_named_bytes32("ICH", mockSTM.initialCutHash());

        emit log_named_bytes32("createNewChain function selector", mockSTM.createNewChain.selector);

        vm.startPrank(deployerAddress);
        vm.mockCall(
            address(mockSTM),
            abi.encodeWithSelector(mockSTM.createNewChain.selector, chainId, address(mockSTM), address(testToken), uint256(chainId * 2), admin, _newChainInitData),
            bytes('')
        );
        bridgeHub.createNewChain(
            chainId,
            address(mockSTM),
            address(testToken),
            uint256(chainId * 2),
            admin,
            _newChainInitData
        );
        vm.stopPrank();

        assertTrue(bridgeHub.stateTransitionManager(newChainId) == address(mockSTM));
        assertTrue(bridgeHub.baseToken(newChainId) == address(testToken));
    }

*/

    function test_proveL2MessageInclusion(
        uint256 mockChainId,
        uint256 mockBatchNumber,
        uint256 mockIndex,
        bytes32[] memory mockProof,
        uint16 randomTxNumInBatch,
        address randomSender,
        bytes memory randomData
    ) public {
        mockChainId = bound(mockChainId, 2, type(uint48).max);
        vm.prank(bridgeOwner);
        bridgeHub.addStateTransitionManager(address(mockSTM));
        
        mockSTM.setStateTransition(mockChainId, address(mockChainContract));

        // We need to set the stateTransitionManager of the mockChainId to mockSTM 
        // There is no function to do that in the bridgeHub
        // So, perhaps we will have to manually set the values in the stateTransitionManager mapping via a foundry cheatcode
        assertTrue(!(bridgeHub.stateTransitionManager(mockChainId) == address(mockSTM)));

        stdstore
            .target(address(bridgeHub))
            .sig("stateTransitionManager(uint256)")
            .with_key(mockChainId)
            .checked_write(address(mockSTM));

        // Now the following statements should be true as well:
        assertTrue(bridgeHub.stateTransitionManager(mockChainId) == address(mockSTM));
        assertTrue(bridgeHub.getStateTransition(mockChainId) == address(mockChainContract));

        // Creating a random L2Message::l2Message so that we pass the correct parameters to `proveL2MessageInclusion`
        L2Message memory l2Message = _createMockL2Message(randomTxNumInBatch, randomSender, randomData);

        // Since we have used random data for the `bridgeHub.proveL2MessageInclusion` function which basically forwards the call
        // to the same function in the mailbox, we will mock the call to the mailbox to return true and see if it works.
        vm.mockCall(
            address(mockChainContract),
            abi.encodeWithSelector(
                mockChainContract.proveL2MessageInclusion.selector,
                mockBatchNumber,
                mockIndex,
                l2Message,
                mockProof 
            ),
            abi.encode(true)
        );

        assertTrue(true);

        assertTrue(bridgeHub.proveL2MessageInclusion(mockChainId,mockBatchNumber,mockIndex,l2Message,mockProof));
        vm.clearMockedCalls();
    }

    function test_proveL2LogInclusion(
        uint256 mockChainId,
        uint256 mockBatchNumber,
        uint256 mockIndex,
        bytes32[] memory mockProof,
        uint8 randomL2ShardId,
        bool randomIsService,
        uint16 randomTxNumInBatch,
        address randomSender,
        bytes32 randomKey,
        bytes32 randomValue
    ) public {
        vm.startPrank(bridgeOwner);
        bridgeHub.addStateTransitionManager(address(mockSTM));
        vm.stopPrank();

        L2Log memory l2Log = _createMockL2Log(
            randomL2ShardId,
            randomIsService,
            randomTxNumInBatch,
            randomSender,
            randomKey,
            randomValue
        );

        vm.mockCall(
            address(bridgeHub),
            abi.encodeWithSelector(
                bridgeHub.proveL2LogInclusion.selector,
                mockChainId,
                mockBatchNumber,
                mockIndex,
                l2Log,
                mockProof    
             ),
            abi.encode(true)
        );

        assertTrue(bridgeHub.proveL2LogInclusion(mockChainId,mockBatchNumber,mockIndex,l2Log,mockProof));
    }

    function test_proveL1ToL2TransactionStatus(
        uint256 randomChainId,
        bytes32 randomL2TxHash,
        uint256 randomL2BatchNumber,
        uint256 randomL2MessageIndex,
        uint16 randomL2TxNumberInBatch,
        bytes32[] memory randomMerkleProof,
        bool randomResultantBool
    ) public {
        vm.startPrank(bridgeOwner);
        bridgeHub.addStateTransitionManager(address(mockSTM));
        vm.stopPrank();

        TxStatus txStatus;

        if (randomChainId % 2 == 0) {
            txStatus = TxStatus.Failure;
        } else {
            txStatus = TxStatus.Success;
        }

        vm.mockCall(
            address(bridgeHub),
            abi.encodeWithSelector(
                bridgeHub.proveL1ToL2TransactionStatus.selector,
                randomChainId,
                randomL2TxHash,
                randomL2BatchNumber,
                randomL2MessageIndex,
                randomL2TxNumberInBatch,
                randomMerkleProof,
                txStatus
            ),
            abi.encode(randomResultantBool)
        );

        assertTrue(bridgeHub.proveL1ToL2TransactionStatus(
            randomChainId, 
            randomL2TxHash,
            randomL2BatchNumber,
            randomL2MessageIndex,
            randomL2TxNumberInBatch,
            randomMerkleProof,
            txStatus
        ) == randomResultantBool);
    }

/////////////////////////////////////////////////////////
// INTERNAL UTILITY FUNCTIONS
/////////////////////////////////////////////////////////

    function _createMockL2Message(
        uint16 randomTxNumInBatch,
        address randomSender,
        bytes memory randomData
    ) internal returns(L2Message memory) {
        L2Message memory l2Message;

        l2Message.txNumberInBatch = randomTxNumInBatch;
        l2Message.sender = randomSender;
        l2Message.data = randomData;

        return l2Message;
    }

    function _createMockL2Log(
        uint8 randomL2ShardId,
        bool randomIsService,
        uint16 randomTxNumInBatch,
        address randomSender,
        bytes32 randomKey,
        bytes32 randomValue
    ) internal returns(L2Log memory) {
        L2Log memory l2Log;

        l2Log.l2ShardId = randomL2ShardId;
        l2Log.isService = randomIsService;
        l2Log.txNumberInBatch = randomTxNumInBatch;
        l2Log.sender = randomSender;
        l2Log.key = randomKey;
        l2Log.value = randomValue;

        return l2Log;
    }

    function _createNewChainInitData(bool isFreezable, bytes4[] memory mockSelectors, address mockInitAddress, bytes memory mockInitCalldata) internal returns (bytes memory) {
        bytes4[] memory singleSelector = new bytes4[](1);
        singleSelector[0] = bytes4(0xabcdef12);
        
        Diamond.FacetCut memory facetCut;
        Diamond.DiamondCutData memory diamondCutData;


        facetCut.facet = address(this); // for a random address, it will fail the check of _facet.code.length > 0
        facetCut.action = Diamond.Action.Add;
        facetCut.isFreezable = isFreezable;
        if(mockSelectors.length == 0) {
            mockSelectors = singleSelector;
        }
        facetCut.selectors = mockSelectors;

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](1);
        facetCuts[0] = facetCut;

        diamondCutData.facetCuts = facetCuts;
        diamondCutData.initAddress = address(0);
        diamondCutData.initCalldata = "";

        mockSTM.setInitialCutHash(diamondCutData);

        return abi.encode(diamondCutData);
    }

/////////////////////////////////////////////////////////
// OLDER (HIGH-LEVEL MOCKED) TESTS
////////////////////////////////////////////////////////

    function test_proveL2MessageInclusion_old(
        uint256 mockChainId,
        uint256 mockBatchNumber,
        uint256 mockIndex,
        bytes32[] memory mockProof,
        uint16 randomTxNumInBatch,
        address randomSender,
        bytes memory randomData
    ) public {
        vm.startPrank(bridgeOwner);
        bridgeHub.addStateTransitionManager(address(mockSTM));
        vm.stopPrank();

        L2Message memory l2Message = _createMockL2Message(randomTxNumInBatch, randomSender, randomData);

        vm.mockCall(
            address(bridgeHub),
            abi.encodeWithSelector(
                bridgeHub.proveL2MessageInclusion.selector,
                mockChainId,
                mockBatchNumber,
                mockIndex,
                l2Message,
                mockProof    
             ),
            abi.encode(true)
        );

        assertTrue(bridgeHub.proveL2MessageInclusion(mockChainId,mockBatchNumber,mockIndex,l2Message,mockProof));
    }
}