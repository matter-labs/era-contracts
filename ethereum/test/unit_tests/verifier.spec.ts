import * as hardhat from 'hardhat';
import { expect } from 'chai';
import { VerifierTest, VerifierRecursiveTest, VerifierTestFactory } from '../../typechain';
import { getCallRevertReason } from './utils';
import { ethers } from 'hardhat';

describe('Verifier test', function () {
    const Q_MOD = '21888242871839275222246405745257275088696311157297823662689037894645226208583';
    const R_MOD = '21888242871839275222246405745257275088548364400416034343698204186575808495617';

    const PROOF = {
        publicInputs: ['0x00461afd95c6bd5a38a01a995f5c292d19a816a139bbc78fc23321c3b8da6243'],
        serializedProof: [
            '0x2b80ef6480b0c1a4ab9ccac1b1f5549d8d0e875e45f445599de5e1a88c3ccf25',
            '0x173e23b955ea8f1972358bbeae3539d96e60494032faf3ada36fb3660f45d752',
            '0x0579422893e75ebcf9ebfefd6bf80513bee55e16f0971779d774cca3227c11a3',
            '0x257c35d228de381fa897042758ef80e4f29c84e8851878d12bae17d7700059e5',
            '0x11cb7bc2927e1ffd32b7c0bf9b75e7f3f2915c33ca525bbb91a39d5ba9d050d1',
            '0x0b396e2027a7e5cbffb8ef303560420c2ec2c25df1325b037208f61679596021',
            '0x1d6feb9bfaf92d370a8041b1669fc901ac083c6f09d815df8e57e3bc0af529c6',
            '0x1dd56a14ac384b74aab66e11dfeb36242a3d3c83c7fc11beed1ebb2d4b921aa3',
            '0x07158e6a51b6354ab3355f298d5cc24948bddd48b0715eff52e0f135936536fc',
            '0x18969b22583c701ef304d793e22d11a56ca9e5b08c20cd877b4fb142dfab852f',
            '0x0c49d474877b03b231cb8aeb592728c93f6b5b62e357a4a77c7dd2818181fc43',
            '0x186e08d590ce9937d193189a0c74890237df96ebc6593dc55b988eae74b9ea44',
            '0x180772b6ef5bd078663a3ba77c3c997b0f9d6a62664a9aa35be4acfe5fd52acb',
            '0x01e19ccd1fa25da95ce7799c6946a64eb12b04bb59fb31b0f48346e844ee06bb',
            '0x0a991aee2dfdea382dd4ed65083c15004d812dcc6017aed812360c1a750f6994',
            '0x2eba4d12e899bd433bc277127d3bb98997ea4953aa092705e185971c5bf95057',
            '0x16ebb143325b1da3c88baf9f69a6911962c89cc34f364cb62f0db35e645baaa3',
            '0x10a1806face2c2906455ac9060155bd648eb18f30a73f0d8214ef75683a2f015',
            '0x2f153ebf44a9ebe05033a085c9c5a20ef002437420badd9723b59d9d9fed7666',
            '0x054da7edbb7dd64940f64d5a46e6d2b70f8d16496657acf01d1bff905e70fe34',
            '0x11a54b951c5f0120c00d6c0ad6b188f21c3d2b955ebea2578926eaf7b0607a34',
            '0x2b5266f06d505e753e8ca5b9a4718f060ed1386313ef9c78b79f7f0474b3ecfc',
            '0x202b9746f651068481021d43598dafcd8aa5e1c662de5baf24507cf8483e517f',
            '0x0e4c150798976c5dbf261b2f50d43e2ae145eec6d63d361b79abdf5a875c7312',
            '0x0d78beaef934700a7a3f63cc94f8ff11f056b770fc7f2e72f6cf2b7b29fb2298',
            '0x26d892a58479bb3a147a7bfd8488ab1e6d97a89b647c886ace6d072134be3474',
            '0x22ee472ea71eb002d8e3b35f93825ef831ab6d321eccc62ae4a1230449f05316',
            '0x18b8f397a1a1db84ce0985252007c532c7d6f0454ef88a446180d6ab3b348321',
            '0x0cbecff5b91f1da7dd1d440f7dd8c48726d7edd5cd119c8f2603fbfba03acd59',
            '0x1f73e67e371a989ef56adc605ce4be99fb1a1200cdc9f15e1cbd9c825a400ed7',
            '0x028667567deeadd469936a07962ba1c7215df0b9d27836cb1160088fc9e44b4c',
            '0x17d4f2ed4b820a8222d2b839035ef0c26ee5ec8e8d2d1a7c16486e54240455cd',
            '0x07a3089dc75c8035530c84d5067f481d42d2a095e9a8bb839c20909b5c978fcc',
            '0x091c2be5555c05bb87116b667992af159e4ad0616c0ec7335570e26c6e627531',
            '0x03c5e763840a185dbc363ed770645d8a0fef39736741848f12d90c3027d3fbfd',
            '0x1f6e675ad9dd1cb9f92086111c47511f510e27c3632527d56c48be1c7b8a03e2',
            '0x23aa0ab9bfb0e38ff029ba5a4cc6f4b8a1dde5b54b1db7435e22c9048ffa7029',
            '0x19a6d569cc94a65fa3685ea1144db7415ceb1cabb11e267c35097dea637536d9',
            '0x04dc0a7c7669340261725af51e4c32eb7f8968b163e70f0beccdf20bd7f771c1',
            '0x1bf9dd4999e0e82da492c292fbb8287bcccd0cb3cd2f1de14f8b4a1592786715',
            '0x257c2aa02452019ea981bc722f0777552be886772eea9a3bdf3257a1e3b75954',
            '0x01b4dc62f39bdb3596ff653b6035e5fb17d278466ba4621a632962a7299523f1',
            '0x0df615b627d9dd8e0d4d7f96c7e30f34d0cbda04c761c191d81cac19de41ccbd',
            '0x1c22d1d281177a86617454edf488d6bb18c6a60222be2121091f4b18d4f5be92'
        ],
        recursiveAggregationInput: []
    };
    let verifier: VerifierTest;

    before(async function () {
        const verifierFactory = await hardhat.ethers.getContractFactory('VerifierTest');
        const verifierContract = await verifierFactory.deploy();
        verifier = VerifierTestFactory.connect(verifierContract.address, verifierContract.signer);
    });

    it('Should verify proof', async () => {
        // Call the verifier directly (though the call, not static call) to add the save the consumed gas into the statistic.
        const calldata = verifier.interface.encodeFunctionData('verify', [
            PROOF.publicInputs,
            PROOF.serializedProof,
            PROOF.recursiveAggregationInput
        ]);
        await verifier.fallback({ data: calldata });

        // Check that proof is verified
        let result = await verifier.verify(PROOF.publicInputs, PROOF.serializedProof, PROOF.recursiveAggregationInput);
        expect(result, 'proof verification failed').true;
    });

    describe('Should verify valid proof with fields values in non standard format', function () {
        it('Public input with dirty bits over Fr mask', async () => {
            let validProof = JSON.parse(JSON.stringify(PROOF));
            // Fill dirty bits
            validProof.publicInputs[0] = ethers.BigNumber.from(validProof.publicInputs[0])
                .add('0xe000000000000000000000000000000000000000000000000000000000000000')
                .toHexString();
            const result = await verifier.verify(
                validProof.publicInputs,
                validProof.serializedProof,
                validProof.recursiveAggregationInput
            );
            expect(result, 'proof verification failed').true;
        });

        it('Elliptic curve points over modulo', async () => {
            let validProof = JSON.parse(JSON.stringify(PROOF));
            // Add modulo to points
            validProof.serializedProof[0] = ethers.BigNumber.from(validProof.serializedProof[0]).add(Q_MOD);
            validProof.serializedProof[1] = ethers.BigNumber.from(validProof.serializedProof[1]).add(Q_MOD).add(Q_MOD);
            const result = await verifier.verify(
                validProof.publicInputs,
                validProof.serializedProof,
                validProof.recursiveAggregationInput
            );
            expect(result, 'proof verification failed').true;
        });

        it('Fr over modulo', async () => {
            let validProof = JSON.parse(JSON.stringify(PROOF));
            // Add modulo to number
            validProof.serializedProof[22] = ethers.BigNumber.from(validProof.serializedProof[22]).add(R_MOD);
            const result = await verifier.verify(
                validProof.publicInputs,
                validProof.serializedProof,
                validProof.recursiveAggregationInput
            );
            expect(result, 'proof verification failed').true;
        });
    });

    describe('Should revert on invalid input', function () {
        it('More than 1 public inputs', async () => {
            let invalidProof = JSON.parse(JSON.stringify(PROOF));
            // Add one more public input to proof
            invalidProof.publicInputs.push(invalidProof.publicInputs[0]);
            const revertReason = await getCallRevertReason(
                verifier.verify(
                    invalidProof.publicInputs,
                    invalidProof.serializedProof,
                    invalidProof.recursiveAggregationInput
                )
            );
            expect(revertReason).equal('loadProof: Proof is invalid');
        });

        it('Empty public inputs', async () => {
            const revertReason = await getCallRevertReason(
                verifier.verify([], PROOF.serializedProof, PROOF.recursiveAggregationInput)
            );
            expect(revertReason).equal('loadProof: Proof is invalid');
        });

        it('More than 44 words for proof', async () => {
            let invalidProof = JSON.parse(JSON.stringify(PROOF));
            // Add one more "serialized proof" input
            invalidProof.serializedProof.push(invalidProof.serializedProof[0]);
            const revertReason = await getCallRevertReason(
                verifier.verify(
                    invalidProof.publicInputs,
                    invalidProof.serializedProof,
                    invalidProof.recursiveAggregationInput
                )
            );
            expect(revertReason).equal('loadProof: Proof is invalid');
        });

        it('Empty serialized proof', async () => {
            const revertReason = await getCallRevertReason(
                verifier.verify(PROOF.publicInputs, [], PROOF.recursiveAggregationInput)
            );
            expect(revertReason).equal('loadProof: Proof is invalid');
        });

        it('Not empty recursive aggregation input', async () => {
            let invalidProof = JSON.parse(JSON.stringify(PROOF));
            // Add one more "recursive aggregation input" value
            invalidProof.recursiveAggregationInput.push(invalidProof.publicInputs[0]);
            const revertReason = await getCallRevertReason(
                verifier.verify(
                    invalidProof.publicInputs,
                    invalidProof.serializedProof,
                    invalidProof.recursiveAggregationInput
                )
            );
            expect(revertReason).equal('loadProof: Proof is invalid');
        });

        it('Elliptic curve point at infinity', async () => {
            let invalidProof = JSON.parse(JSON.stringify(PROOF));
            // Change first point to point at infinity (encode as (0, 0) on EVM)
            invalidProof.serializedProof[0] = ethers.constants.HashZero;
            invalidProof.serializedProof[1] = ethers.constants.HashZero;
            const revertReason = await getCallRevertReason(
                verifier.verify(
                    invalidProof.publicInputs,
                    invalidProof.serializedProof,
                    invalidProof.recursiveAggregationInput
                )
            );
            expect(revertReason).equal('loadProof: Proof is invalid');
        });
    });

    it('Should failed with invalid public input', async () => {
        const revertReason = await getCallRevertReason(
            verifier.verify([ethers.constants.HashZero], PROOF.serializedProof, PROOF.recursiveAggregationInput)
        );
        expect(revertReason).equal('invalid quotient evaluation');
    });

    it('Should return correct Verification key hash', async () => {
        const vksHash = await verifier.verificationKeyHash();
        expect(vksHash).equal('0x1400ce39763501f086ab7210ec2f020c0188cad25757ef756a7ba31fa62b1842');
    });
});

describe('Verifier with recursive part test', function () {
    const Q_MOD = '21888242871839275222246405745257275088696311157297823662689037894645226208583';
    const R_MOD = '21888242871839275222246405745257275088548364400416034343698204186575808495617';

    const PROOF = {
        publicInputs: ['0x00461afd95c6bd5a38a01a995f5c292d19a816a139bbc78fc23321c3b8da6243'],
        serializedProof: [
            '0x2b80ef6480b0c1a4ab9ccac1b1f5549d8d0e875e45f445599de5e1a88c3ccf25',
            '0x173e23b955ea8f1972358bbeae3539d96e60494032faf3ada36fb3660f45d752',
            '0x0579422893e75ebcf9ebfefd6bf80513bee55e16f0971779d774cca3227c11a3',
            '0x257c35d228de381fa897042758ef80e4f29c84e8851878d12bae17d7700059e5',
            '0x11cb7bc2927e1ffd32b7c0bf9b75e7f3f2915c33ca525bbb91a39d5ba9d050d1',
            '0x0b396e2027a7e5cbffb8ef303560420c2ec2c25df1325b037208f61679596021',
            '0x1d6feb9bfaf92d370a8041b1669fc901ac083c6f09d815df8e57e3bc0af529c6',
            '0x1dd56a14ac384b74aab66e11dfeb36242a3d3c83c7fc11beed1ebb2d4b921aa3',
            '0x07158e6a51b6354ab3355f298d5cc24948bddd48b0715eff52e0f135936536fc',
            '0x18969b22583c701ef304d793e22d11a56ca9e5b08c20cd877b4fb142dfab852f',
            '0x0c49d474877b03b231cb8aeb592728c93f6b5b62e357a4a77c7dd2818181fc43',
            '0x186e08d590ce9937d193189a0c74890237df96ebc6593dc55b988eae74b9ea44',
            '0x180772b6ef5bd078663a3ba77c3c997b0f9d6a62664a9aa35be4acfe5fd52acb',
            '0x01e19ccd1fa25da95ce7799c6946a64eb12b04bb59fb31b0f48346e844ee06bb',
            '0x0a991aee2dfdea382dd4ed65083c15004d812dcc6017aed812360c1a750f6994',
            '0x2eba4d12e899bd433bc277127d3bb98997ea4953aa092705e185971c5bf95057',
            '0x16ebb143325b1da3c88baf9f69a6911962c89cc34f364cb62f0db35e645baaa3',
            '0x10a1806face2c2906455ac9060155bd648eb18f30a73f0d8214ef75683a2f015',
            '0x2f153ebf44a9ebe05033a085c9c5a20ef002437420badd9723b59d9d9fed7666',
            '0x054da7edbb7dd64940f64d5a46e6d2b70f8d16496657acf01d1bff905e70fe34',
            '0x11a54b951c5f0120c00d6c0ad6b188f21c3d2b955ebea2578926eaf7b0607a34',
            '0x2b5266f06d505e753e8ca5b9a4718f060ed1386313ef9c78b79f7f0474b3ecfc',
            '0x202b9746f651068481021d43598dafcd8aa5e1c662de5baf24507cf8483e517f',
            '0x0e4c150798976c5dbf261b2f50d43e2ae145eec6d63d361b79abdf5a875c7312',
            '0x0d78beaef934700a7a3f63cc94f8ff11f056b770fc7f2e72f6cf2b7b29fb2298',
            '0x26d892a58479bb3a147a7bfd8488ab1e6d97a89b647c886ace6d072134be3474',
            '0x22ee472ea71eb002d8e3b35f93825ef831ab6d321eccc62ae4a1230449f05316',
            '0x18b8f397a1a1db84ce0985252007c532c7d6f0454ef88a446180d6ab3b348321',
            '0x0cbecff5b91f1da7dd1d440f7dd8c48726d7edd5cd119c8f2603fbfba03acd59',
            '0x1f73e67e371a989ef56adc605ce4be99fb1a1200cdc9f15e1cbd9c825a400ed7',
            '0x028667567deeadd469936a07962ba1c7215df0b9d27836cb1160088fc9e44b4c',
            '0x17d4f2ed4b820a8222d2b839035ef0c26ee5ec8e8d2d1a7c16486e54240455cd',
            '0x07a3089dc75c8035530c84d5067f481d42d2a095e9a8bb839c20909b5c978fcc',
            '0x091c2be5555c05bb87116b667992af159e4ad0616c0ec7335570e26c6e627531',
            '0x03c5e763840a185dbc363ed770645d8a0fef39736741848f12d90c3027d3fbfd',
            '0x1f6e675ad9dd1cb9f92086111c47511f510e27c3632527d56c48be1c7b8a03e2',
            '0x23aa0ab9bfb0e38ff029ba5a4cc6f4b8a1dde5b54b1db7435e22c9048ffa7029',
            '0x19a6d569cc94a65fa3685ea1144db7415ceb1cabb11e267c35097dea637536d9',
            '0x04dc0a7c7669340261725af51e4c32eb7f8968b163e70f0beccdf20bd7f771c1',
            '0x1bf9dd4999e0e82da492c292fbb8287bcccd0cb3cd2f1de14f8b4a1592786715',
            '0x257c2aa02452019ea981bc722f0777552be886772eea9a3bdf3257a1e3b75954',
            '0x01b4dc62f39bdb3596ff653b6035e5fb17d278466ba4621a632962a7299523f1',
            '0x0df615b627d9dd8e0d4d7f96c7e30f34d0cbda04c761c191d81cac19de41ccbd',
            '0x1c22d1d281177a86617454edf488d6bb18c6a60222be2121091f4b18d4f5be92'
        ],
        recursiveAggregationInput: [
            '0x04fdf01a2faedb9e3a620bc1cd8ceb4b0adac04631bdfa9e7e9fc15e35693cc0',
            '0x1419728b438cc9afa63ab4861753e0798e29e08aac0da17b2c7617b994626ca2',
            '0x23ca418458f6bdc30dfdbc13b80c604f8864619582eb247d09c8e4703232897b',
            '0x0713c1371914ac18d7dced467a8a60eeca0f3d80a2cbd5dcc75abb6cbab39f39'
        ]
    };
    let verifier: VerifierRecursiveTest;

    before(async function () {
        const verifierFactory = await hardhat.ethers.getContractFactory('VerifierRecursiveTest');
        const verifierContract = await verifierFactory.deploy();
        verifier = VerifierTestFactory.connect(verifierContract.address, verifierContract.signer);
    });

    it('Should verify proof', async () => {
        // Call the verifier directly (though the call, not static call) to add the save the consumed gas into the statistic.
        const calldata = verifier.interface.encodeFunctionData('verify', [
            PROOF.publicInputs,
            PROOF.serializedProof,
            PROOF.recursiveAggregationInput
        ]);
        await verifier.fallback({ data: calldata });

        // Check that proof is verified
        let result = await verifier.verify(PROOF.publicInputs, PROOF.serializedProof, PROOF.recursiveAggregationInput);
        expect(result, 'proof verification failed').true;
    });

    describe('Should verify valid proof with fields values in non standard format', function () {
        it('Public input with dirty bits over Fr mask', async () => {
            let validProof = JSON.parse(JSON.stringify(PROOF));
            // Fill dirty bits
            validProof.publicInputs[0] = ethers.BigNumber.from(validProof.publicInputs[0])
                .add('0xe000000000000000000000000000000000000000000000000000000000000000')
                .toHexString();
            const result = await verifier.verify(
                validProof.publicInputs,
                validProof.serializedProof,
                validProof.recursiveAggregationInput
            );
            expect(result, 'proof verification failed').true;
        });

        it('Elliptic curve points over modulo', async () => {
            let validProof = JSON.parse(JSON.stringify(PROOF));
            // Add modulo to points
            validProof.serializedProof[0] = ethers.BigNumber.from(validProof.serializedProof[0]).add(Q_MOD);
            validProof.serializedProof[1] = ethers.BigNumber.from(validProof.serializedProof[1]).add(Q_MOD).add(Q_MOD);
            const result = await verifier.verify(
                validProof.publicInputs,
                validProof.serializedProof,
                validProof.recursiveAggregationInput
            );
            expect(result, 'proof verification failed').true;
        });

        it('Fr over modulo', async () => {
            let validProof = JSON.parse(JSON.stringify(PROOF));
            // Add modulo to number
            validProof.serializedProof[22] = ethers.BigNumber.from(validProof.serializedProof[22]).add(R_MOD);
            const result = await verifier.verify(
                validProof.publicInputs,
                validProof.serializedProof,
                validProof.recursiveAggregationInput
            );
            expect(result, 'proof verification failed').true;
        });
    });

    describe('Should revert on invalid input', function () {
        it('More than 1 public inputs', async () => {
            let invalidProof = JSON.parse(JSON.stringify(PROOF));
            // Add one more public input to proof
            invalidProof.publicInputs.push(invalidProof.publicInputs[0]);
            const revertReason = await getCallRevertReason(
                verifier.verify(
                    invalidProof.publicInputs,
                    invalidProof.serializedProof,
                    invalidProof.recursiveAggregationInput
                )
            );
            expect(revertReason).equal('loadProof: Proof is invalid');
        });

        it('Empty public inputs', async () => {
            const revertReason = await getCallRevertReason(
                verifier.verify([], PROOF.serializedProof, PROOF.recursiveAggregationInput)
            );
            expect(revertReason).equal('loadProof: Proof is invalid');
        });

        it('More than 44 words for proof', async () => {
            let invalidProof = JSON.parse(JSON.stringify(PROOF));
            // Add one more "serialized proof" input
            invalidProof.serializedProof.push(invalidProof.serializedProof[0]);
            const revertReason = await getCallRevertReason(
                verifier.verify(
                    invalidProof.publicInputs,
                    invalidProof.serializedProof,
                    invalidProof.recursiveAggregationInput
                )
            );
            expect(revertReason).equal('loadProof: Proof is invalid');
        });

        it('Empty serialized proof', async () => {
            const revertReason = await getCallRevertReason(
                verifier.verify(PROOF.publicInputs, [], PROOF.recursiveAggregationInput)
            );
            expect(revertReason).equal('loadProof: Proof is invalid');
        });

        it('More than 4 words for recursive aggregation input', async () => {
            let invalidProof = JSON.parse(JSON.stringify(PROOF));
            // Add one more "recursive aggregation input" value
            invalidProof.recursiveAggregationInput.push(invalidProof.recursiveAggregationInput[0]);
            const revertReason = await getCallRevertReason(
                verifier.verify(
                    invalidProof.publicInputs,
                    invalidProof.serializedProof,
                    invalidProof.recursiveAggregationInput
                )
            );
            expect(revertReason).equal('loadProof: Proof is invalid');
        });

        it('Empty recursive aggregation input', async () => {
            const revertReason = await getCallRevertReason(
                verifier.verify(PROOF.publicInputs, PROOF.serializedProof, [])
            );
            expect(revertReason).equal('loadProof: Proof is invalid');
        });

        it('Elliptic curve point at infinity', async () => {
            let invalidProof = JSON.parse(JSON.stringify(PROOF));
            // Change first point to point at infinity (encode as (0, 0) on EVM)
            invalidProof.serializedProof[0] = ethers.constants.HashZero;
            invalidProof.serializedProof[1] = ethers.constants.HashZero;
            const revertReason = await getCallRevertReason(
                verifier.verify(
                    invalidProof.publicInputs,
                    invalidProof.serializedProof,
                    invalidProof.recursiveAggregationInput
                )
            );
            expect(revertReason).equal('loadProof: Proof is invalid');
        });
    });

    it('Should failed with invalid public input', async () => {
        const revertReason = await getCallRevertReason(
            verifier.verify([ethers.constants.HashZero], PROOF.serializedProof, PROOF.recursiveAggregationInput)
        );
        expect(revertReason).equal('invalid quotient evaluation');
    });

    it('Should failed with invalid recursive aggregative input', async () => {
        const revertReason = await getCallRevertReason(
            verifier.verify(PROOF.publicInputs, PROOF.serializedProof, [1, 2, 1, 2])
        );
        expect(revertReason).equal('finalPairing: pairing failure');
    });

    it('Should return correct Verification key hash', async () => {
        const vksHash = await verifier.verificationKeyHash();
        expect(vksHash).equal('0x941b4da215420ba6a39c1c94ada871e89749bd84fdeedd079acb3f0d0e1b2acd');
    });
});
