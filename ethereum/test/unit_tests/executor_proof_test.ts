import * as hardhat from 'hardhat';
import { expect } from 'chai';
import { ExecutorProvingTest, ExecutorProvingTestFactory } from '../../typechain';
import { getCallRevertReason } from './utils';
import { ethers } from 'hardhat';

describe('Executor test', function () {


    let executor: ExecutorProvingTest;

    before(async function () {
        const factory = await hardhat.ethers.getContractFactory('ExecutorProvingTest');
        const executorContract = await factory.deploy();
        executor = ExecutorProvingTestFactory.connect(executorContract.address, executorContract.signer);
    });

    /// This test is based on a block generated in a local system.
    it('Should verify proof_generated', async () => {
        let bootloaderHash = "0x01000923e7c6e9e116c813f5e9b45eda88e3892d9150839bd6004c2df1846d46";
        let aaHash = "0x0100067d70019d4919b5c8423df00fa89a5c53e734bccc1ad4a92e99df7474ab";
        let setResult = await executor.setHashes(aaHash, bootloaderHash);
        let finish = await setResult.wait();


        console.log("Set result: {}", setResult);
        console.log("finish: {} ", finish);


        // Call the verifier directly (though the call, not static call) to add the save the consumed gas into the statistic.
        // Check that proof is verified

        let prev_commitment = await executor.createBatchCommitment({
            // ignored??
            batchNumber: 1,
            // ignored??
            timestamp: 100,
            indexRepeatedStorageChanges: 23,
            newStateRoot: "0x38a3e641bf44aca21abf4cdfa2cac66cd1f222149e24105f6bfac98e0fc87503",
            // ignored(?)
            numberOfLayer1Txs: 100,
            // ignored(?)
            priorityOperationsHash: "0x05dc05911af0aee6a0950ee36dad423981cf05a58cfdb479109bff3c2262eaac",
            // important
            bootloaderHeapInitialContentsHash: "0x05dc05911af0aee6a0950ee36dad423981cf05a58cfdb479109bff3c2262eaac",
            // important
            eventsQueueStateHash: "0x05dc05911af0aee6a0950ee36dad423981cf05a58cfdb479109bff3c2262eaac",
            // important
            systemLogs: "0x05dc05911af0aee6a0950ee36dad423981cf05a58cfdb479109bff3c2262eaac",
            // ignored??
            totalL2ToL1Pubdata: "0x05dc05911af0aee6a0950ee36dad423981cf05a58cfdb479109bff3c2262eaac",
        }, "0x05dc05911af0aee6a0950ee36dad423981cf05a58cfdb479109bff3c2262eaac");

        console.log("Commitment is : " + prev_commitment);

        let nextBatch = {
            // ignored??
            batchNumber: 1,
            // ignored??
            timestamp: 100,
            indexRepeatedStorageChanges: 83,
            newStateRoot: "0x0557c172fdfa63645c318a741c7c53b38a8fcf12421d8d4ce311e4e633dbcafb",
            // ignored(?)
            numberOfLayer1Txs: 10,
            // ignored(?)
            priorityOperationsHash: "0x05dc05911af0aee6a0950ee36dad423981cf05a58cfdb479109bff3c2262eaac",
            // important (set)
            bootloaderHeapInitialContentsHash: "0x4f767dd4bfe68c96c003880385488a27ecb419429120c18933632f43f834012d",
            // important (set)
            eventsQueueStateHash: "0xe9a00716e01f52a8a7452f4f88dfe2d118afd791bc037ee8d6b7f0e9578452f7",
            // important (this is a concat of 88-bytes representations of system logs only )
            systemLogs: "0x00000000000000000000000000000000000000000000800b000000000000000000000000000000000000000000000000000000000000000438a3e641bf44aca21abf4cdfa2cac66cd1f222149e24105f6bfac98e0fc875030000000a000000000000000000000000000000000000800b000000000000000000000000000000000000000000000000000000000000000300000000000000000000000065128e9900000000000000000000000065128e9a0001000a0000000000000000000000000000000000008001000000000000000000000000000000000000000000000000000000000000000557e010f70b415aa4ff992e4af69c8600cb618563440d571228847af9d4967ca90001000a00000000000000000000000000000000000080010000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000a0001000a000000000000000000000000000000000000800800000000000000000000000000000000000000000000000000000000000000003b7a24f0f455c8396e22f177266ac886ab64b6807d0a21d49184bb1caa1ebf460001000a00000000000000000000000000000000000080080000000000000000000000000000000000000000000000000000000000000001c8a9099ff8a8076ebf23ddf8efbd3bec81513a036d3cdecb81a083124371b9540001000a00000000000000000000000000000000000080080000000000000000000000000000000000000000000000000000000000000002238d154325ef12895e2d94442a559d92de723a6cc6abf218297eea120f373ad7",
            // ignored??
            totalL2ToL1Pubdata: "0x05dc05911af0aee6a0950ee36dad423981cf05a58cfdb479109bff3c2262eaac",
        };

        // L2 -> L1 pubdata hash missing.. need another data string.
        //let processL2Logs = await executor.processL2Logs(nextBatch, "0x0000000000000000000000000000000000000000000000000000000000000000");
        //console.log("process l2: {}", processL2Logs);


        let next_commitment = await executor.createBatchCommitment({
            // ignored??
            batchNumber: 1,
            // ignored??
            timestamp: 100,
            indexRepeatedStorageChanges: 83,
            newStateRoot: "0x0557c172fdfa63645c318a741c7c53b38a8fcf12421d8d4ce311e4e633dbcafb",
            // ignored(?)
            numberOfLayer1Txs: 10,
            // ignored(?)
            priorityOperationsHash: "0x05dc05911af0aee6a0950ee36dad423981cf05a58cfdb479109bff3c2262eaac",
            // important (set)
            bootloaderHeapInitialContentsHash: "0x4f767dd4bfe68c96c003880385488a27ecb419429120c18933632f43f834012d",
            // important (set)
            eventsQueueStateHash: "0xe9a00716e01f52a8a7452f4f88dfe2d118afd791bc037ee8d6b7f0e9578452f7",
            // important (this is a concat of 88-bytes representations of system logs only )
            systemLogs: "0x00000000000000000000000000000000000000000000800b000000000000000000000000000000000000000000000000000000000000000438a3e641bf44aca21abf4cdfa2cac66cd1f222149e24105f6bfac98e0fc875030000000a000000000000000000000000000000000000800b000000000000000000000000000000000000000000000000000000000000000300000000000000000000000065128e9900000000000000000000000065128e9a0001000a0000000000000000000000000000000000008001000000000000000000000000000000000000000000000000000000000000000557e010f70b415aa4ff992e4af69c8600cb618563440d571228847af9d4967ca90001000a00000000000000000000000000000000000080010000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000a0001000a000000000000000000000000000000000000800800000000000000000000000000000000000000000000000000000000000000003b7a24f0f455c8396e22f177266ac886ab64b6807d0a21d49184bb1caa1ebf460001000a00000000000000000000000000000000000080080000000000000000000000000000000000000000000000000000000000000001c8a9099ff8a8076ebf23ddf8efbd3bec81513a036d3cdecb81a083124371b9540001000a00000000000000000000000000000000000080080000000000000000000000000000000000000000000000000000000000000002238d154325ef12895e2d94442a559d92de723a6cc6abf218297eea120f373ad7",
            // ignored??
            totalL2ToL1Pubdata: "0x05dc05911af0aee6a0950ee36dad423981cf05a58cfdb479109bff3c2262eaac",
        }, "0xeea6149a262aa6b1e48c805dc66a813be6e7641f03ea4fd9009c1861aa169b0a");

        console.log("This block Commitment is : " + next_commitment);



        // prev commitment: 0x1c
        // current commit: 0x582
        let result = await executor.getBatchProofPublicInput("0x1c9c3e2d4558f0e60fb5ecaa389840a566eb4ab358b024bd9be11556b12d1811",
            "0x582f296124752304622cae4be6f8f8281f2db9e18dc19380ef2e3acaaecdafbe", {
            recursiveAggregationInput: [],
            serializedProof: []
        }, {

            recursionNodeLevelVkHash: "0x5a3ef282b21e12fe1f4438e5bb158fc5060b160559c5158c6389d62d9fe3d080",
            recursionLeafLevelVkHash: "0x72167c43a46cf38875b267d67716edc4563861364a3c03ab7aee73498421e828",
            // ignored??
            recursionCircuitsSetVksHash: "0x05dc05911af0aee6a0950ee36dad423981cf05a58cfdb479109bff3c2262eaac"
        });


        // Generated from: RESULT: Ok([0x000303c87fb119f9, 0x00c75bcaf66ec23c, 0x0074c1a04f04870c, 0x00a3dd954bb76c14])
        // Final result should have been: 0xa3dd954bb76c1474c1a04f04870cc75bcaf66ec23c0303c87fb119f9
        console.log("Result is: " + result.toHexString());

        expect(result.toHexString(), "").to.be.equal("0x0303c87fb119f9c75bcaf66ec23c74c1a04f04870ca3dd954bb76c140ecf2741");
    });


})