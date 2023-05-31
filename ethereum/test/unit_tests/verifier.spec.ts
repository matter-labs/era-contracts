// import * as hardhat from 'hardhat';
// import { expect } from 'chai';
// import { Verifier, VerifierFactory } from '../../typechain';
//
// describe('Verifier tests', function () {
//     const PROOF = {
//         public_inputs: ['0x143e5a9ae11ce7c212304dd3f434ac8dff25332ad8adfc4203d95c7b4aea2f'],
//         serialized_proof: [
//             '0x010f11270a0ddb00a666e1c6532065905092112e5fad0d1c9b615f9f3065c8dd',
//             '0x014f93fc29fed9372193fc9535150c8d4ebe2b49fad387fc230344d16149a9bb',
//             '0x23a4dc9d7f679cd15923c6dfc0e8e457edc0a3862a824e5aa4702ceabda0a047',
//             '0x948cb016bb21c4dd9c8cf107ddd4ddbc308eff7743c019d680fb4d8587d05a',
//             '0x133b7e7e63f70910acce3feaf44d89cf893d410b0880f87ff308ef44c5aee773',
//             '0x24878e90e224cb4246492115e94e79809dce757ca7a4decbcff6092ea5ce510a',
//             '0x2e172ed1fb272478ca968965488da0b5c18d7fce9241f4a8ad295f01ba8478bd',
//             '0x108bbbc2153a50515d9d8b2a5757a4b4d62efd3fd425da9d8b9a1b2f795421ea',
//             '0x21ebacd434b555e1a82af0e0535f6aa47c9b38006a10f79f0fe8a52df474c51c',
//             '0x1c2c8ca9750ed300dbc06ade43e69acbb614592a305c8e7ef4bf8aee50865fc8',
//             '0x9e1b717a35bb31ab11d7ecd5802f7e598ca7918f79d575f17921d6681f7e79',
//             '0x038209dfd674204198de3d291ca47b4212dfd4d6a20a2b360b1a6138623094ac',
//             '0x1036e836c58c78400fd7b30e337e26d765b19d51d3d3447a01c0a003306b7efc',
//             '0x1e7f110f8601fe84c79bb7a6c75cbd8cb92658ef563245280b9457c2a69139',
//             '0x01cc91f946efb91a4e14f2d0790f73d6ba647aa414bc2e6fddd800d925371d82',
//             '0x04e93b5790dd468d77df0b9b8bea80dc2ebe525412db5e724510e2feb7cad955',
//             '0x06ebd8b3c96266a6fb9ff923431147bef97d701d1a2333bbf91cbfdb276080f2',
//             '0x2d5dab85db469066124fb7706b9c710773c05d8c360efc1c31992e336762c7d7',
//             '0x114f8bf9a2050f2763affa8d7213c22adbcf01e42e785d3441ffea118888243d',
//             '0x2692422d6933cdf24274fd29cef859856cc169e5d2e72b31deb620001cf3b940',
//             '0x2ca0abed52054af163f83d0d6fabf082579d20bbb734eb9bf4e33a28cd8b4bdd',
//             '0x0a44d037425f05a738e6ebc2e44127c05d6a6564a9091bab3407c223dbd2900f',
//             '0x2e74025e8f7b63473b2639e8e876c04ce28907892ce6f56d976f16a9d5d3d314',
//             '0x0caa73604a585da384d06686f4cc7b01f4cdc9627ff9b32b954048da29538f08',
//             '0x0a79a1acfe5cc1064672fe805b8efa3b3730dfa6558a17f323ad94bc47ab6d4a',
//             '0x23922b78fa043a80c9cfdae2907a050804e7821e71d8fdcabeaece0d47eba0ad',
//             '0x27394d6a7c23dff26d46eb9a0a4ded65f663359db6dfaf5d020bbdf4defd4a',
//             '0x21be59cd244bd991ddf098d632c68a61a1f5834567906aa6129aa1e38d269f6c',
//             '0x0fb1ba84318af85e01302d8610a3810aea901f783e4f38cf01130f4774569079',
//             '0x26fdabdf196e08cbb15d242b74604fdf5466e34ac457f7776b166f9e74d4d09b',
//             '0x15aae20ac54fb73ac5f19f5e8d8234bc619c2f93e14894e53e3a39059e9904d4',
//             '0x23cee98e838bc6f77a12ceb104f87f6a72974827e8a64698e18c3485a4e09544',
//             '0x1a0a8d84b5833271ad69ee59116ba97d1dd86efa77f75486a049195b47c499bd',
//             '0x1fe6778aa9d3d435ad39d30564ecf51751db67f12669fa1bdae3f84c163f75c7',
//             '0x0feb723ac8ddd1a21c6adaedc36c86d1f6d5177183afa8d288ba699bac17b1c5',
//             '0x02bdd5679a965f57d8e1f71306c0adb67ccf46163b4538af86aa49d8d917590f',
//             '0x1ce9caaed894da866c8a904161f4490c4381e073dbc1959cff9fbdc5ad8395a2',
//             '0x303af8ffd4f4c8accf6bec9c91bb29ab90a334291134aaa3fcc392f156fc8bc2',
//             '0x0902d7167e48f2a66924d91098ce44aaf35c6c45df42ab66fea90bb4935e26e8',
//             '0x15fb71a86f46171b9fb5e77f2789b663643450e0ecc4a321089518f21f0838f7',
//             '0x0b1a21e343b967eed4b93b0764708d8ec57597848658bf8777dff4541faf0bf2',
//             '0x20117d30650de2bb1812f77f853ae99e5de5ff48587f5e4277061ad19bfcbd30',
//             '0x0e4d544ce4205b02bf74dd6e2dd6d132a3dd678a09fef6f98f3917b04bf1583e',
//             '0x2673b5373e44ec861370732e2d2a8eeb2b719e12f4d7e085c2ee7bfdc4e9475f'
//         ]
//     };
//     let verifier: Verifier;
//
//     before(async function () {
//         const verifierFactory = await hardhat.ethers.getContractFactory('Verifier');
//         const verifierContract = await verifierFactory.deploy();
//         verifier = VerifierFactory.connect(verifierContract.address, verifierContract.signer);
//     });
//
//     it('Should verify proof', async () => {
//         // Call the verifier directly (though the call, not static call) to add the save the consumed gas into the statistic.
//         const calldata = verifier.interface.encodeFunctionData('verify_serialized_proof', [
//             PROOF.public_inputs,
//             PROOF.serialized_proof
//         ]);
//         await verifier.fallback({ data: calldata });
//
//         // Check that proof is verified
//         let result = await verifier.verify_serialized_proof(PROOF.public_inputs, PROOF.serialized_proof);
//         expect(result, 'proof verification failed').true;
//     });
// });
