// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ZISK_SNARK_PROOF_LENGTH} from "contracts/common/Config.sol";
import {IZiskSnarkVerifier} from "contracts/state-transition/chain-interfaces/IZiskSnarkVerifier.sol";
import {PilfflonkVerifier} from "contracts/state-transition/verifiers/PilfflonkVerifier.sol";
import {ZiskVerifier} from "contracts/state-transition/verifiers/ZiskVerifier.sol";

/// @notice Real-crypto anchor for the ZiSK verifier stack.
/// @dev A fixture holds a 2,208-byte BN254 pilfflonk SNARK plus the 576-byte
///      public values `programVK(32) || guest publics(512) || rootCVadcopFinal(32)`,
///      whose single public signal is `sha256(publicValues) % r`. The
///      guest-publics section is 64 little-endian u64 slots, one per guest
///      public; a guest public holds a 32-bit value, so each slot carries four
///      significant bytes and four zero pad bytes.
///
///      The BATCH fixture is the inner state-transition proof of batch 1, so
///      its wire bytes [0..32] hold the INNER programVK and its first eight
///      guest-public slots, bytes [32..96], the raw batch commitment. The
///      AGGREGATED fixture proves the whole range, so its wire bytes [0..32]
///      hold the AGGREGATOR programVK and its first eight slots the binding
///      digest `keccak256(innerProgramVK || rootCVadcopFinal || chainedPI)`.
///
///      `ZiskVerifier.verify` rebuilds exactly those 576 aggregated bytes from
///      its own pins and the batch public inputs, so the aggregated fixture
///      drives the production path end to end: the reconstruction AND the real
///      pairing, through the vendored `PilfflonkVerifier`.
///      MultiProofRangeVectorTest pins the same vector against a signal
///      stand-in, which is what lets it name the exact expected signal.
/// @dev Fixtures: the zksync-os-zisk ZiSK 1.4.0-alpha pins, guest ELFs
///      reproduced from the release 0.0.11 pins in GPU run
///      https://github.com/matter-labs/zksync-os-zisk/actions/runs/45818119218.
contract ZiskVerifierRealProofTest is Test {
    /// @dev Real 2,208-byte BN254 pilfflonk SNARK of batch 1 (inner guest).
    bytes internal constant BATCH_PROOF =
        hex"14c08d198a11ca7d08007612fb2cf9e5133acab0ffd3929ba0b55df4800632e422563e08a842acc7a42203f82aa348b544ab1a45af92d48bef4d3fe8080378391bf0d16d560ceac957c88000d4ce5b0955d747c2c5ed0d872112f273ec6d5d0b17432d7ea4c93c00df348e0ef2137cfc2dd6c36d18652a12e2140155fa3ec0aa18f43ea264bec1d4ebfabdd0d12cb327f47b9e596ecf7ae1efefecedfda4708b14b47be47e047b40294c4ec0191408fe3bdaad2085349147a5204c41e7ef6cd6279c52927305ad6d13a3676ed6042e4a5c53cddbc47d0bbd81bff61814f5427d26af65fe473dc2ab82f768af842d5b73c74f49bc880ea1e94de28fe6ef01ccff25fb7c0d4a9d79f84f0c1ac0c12f6b6db4241247bdd5a4b83455b91b81cb2467052feb869cdd9138f79236979e964967e7f70c812404412cd75606fade6acc852f4a1f07bfc9d84ea07c112a7e4a3c4b6ddecdb17e9dc922036a971be33d3da11c0b60a68965e0e2f6ccd6d704dfe5cd1ebab19c0a0268684f16c4bf33e1dae413bbd8e676296841a051b81491da08e69a38f5a1949689b264793eaaca92926d11ba69c784a6a6ad15b213b7935fb94c958d1a61120a38433bb6fd937497e2c228b5df60ddb12e98069a3364fbd25f4cde1ab1530381e8cd0cd6445540d243bc017f68b6d16ad27d081a867d21cc43ee12807b98204345abf35c58866c606f080bd0496ec205eeda85250ffaf73c575073bdb884aec64cdf619482bef81ca04a03774d355f281e477065fb4fdd342334eae4de03fa4c16d3a98cbc6fc0b792b017472107b1a72907ec791ef26c7061f9c7ae1f37a6dc61591c88b6a970d223a82471c86c11c07ec49acedb45fa6c1cdd4f210c2eb1462f244926dfdb84b6bc22028f626e9b5ab7864a2f41f20ddcb87b777fdcac967d3aad5ce7dc9f9f23b7b500493f2de38a2d477f034cc135ff6a6b7c1250ec747cbcddbe3c404d7c4ce92611d53620b2e8aaa8979aa2b6578435367bedf7961b93b28a7d6a04d929269610001e0eac99b1ba6f59adaca659992437f4d1d36cd9f0e9d461b202bcf36fe5b104b623123f62332114069198d506c45b4cbddd76227c752f7f95fbaf5bcdb7df16058d2d124e7718b71ecc36cc0823f79108504032661969a401dc6f7d2e15aa1fa657b54e3f199a7ee8bd70b7f8d315582a2b87bef75ec36b8d58bf26288eab1fc7949941edc44c01daed0b245bd4f9a418493b0ddf46ff400edaf0ec47416713bc096bc664fffccb790a14ea08151b3d6550960f228897aece3e68772b58a30ef3f4b3c9f4762d2862dbb4ab13f4005495a0a58fa63072d3ea77369071bf3b2aef08ea2d1a331a887ca3f9559d41892335570140fb6b23a303ad3b41e578062f6ef44b8535515a1f4c4c14f2c0c7f4fa66913b9260df6990de77fdc2b4590f0397f0d1fcb6f51c9fef8f265e3b853158e4ae7abbcea601e37a8880f98b28fe1d54bcedb048c97c5654b4fac9a03d33a3e5109e5d005be3fc362678e4feb9161dcb1af04e8c0f88757b330e33812093b9d3b39c587051bf9e377dfdb67562bd30084a1875911dca7b6725add234b73eabec385be26ec8e7cdb7f931316838902676733dba4787b5b38b795617e27fd4a8e433c1d875c1f2a9ded2e7960a4ca5264380115129d5cfcf42ba88f3e72e6312d8411a62a8fbb0eade447637640d661a9883acd33950c7ae213e98ec90a76853411112d78f941c1dba70d97d30bddc25cf075bcb48129359cfca6a831ab8f02c082e8f2b2cba1e0f72e2c876d9312a0d74f9804e47791d97085c2b4adb82cec5795816a89109cb275a23175a3acf660f7b1638800d00f525bfb9799e3bcae8828a0d175d142d62f5412492a44d95ec0dc177b57b3ad369fe10b2fc5a3e4439f7539ba8e4e0942fc61f317cc77ec71c1da0c16e0a42d4dac030c980318e8318e24dea50101b97838afc3c1054fa128417cbcd7c37daa16c7c4dd64126a840959481309a6bd87f44661d89b8cd0018592caa85ea15c960f3247213a0df14c4fc930a45caec7733226e5d50bb95d7f27a0d927adf3af5c40ec89f08c5b76de7509d79e084171efe87250e17c566e67f01207fde0cb9acfba22850fc8ebb3b9299e7faddd406aaccdd43d8a0162fe8b72b2280a629589842e70b486650e3ae4e6addccabe72e5ecd9af23c6b086edd3a1c148befbd110150ed73d8870402537ce46ca471a81f7aac63af71efadd473d1b602dbc9f0fffad8e804ec6a03b2ee7c58548cd770ca85ef6277b5ac7382e4d9800f5e4daba913f2cd47e2795a5b3669df357172671dfcd53d5df7f7c81f4313cf1224d92bd5bc3e0850adcb322b939a7953c17ebe672380ace648aa37eb9879a225909c2a39cbab70abce1791e66713035966f9d7ffb9e84d729d0119d2aa79b41ecc93f193a9d703ef75fd6826309b6632bf3a1913ec783129389a5b78485cbf1072ce26fcb39bc323bf59ed87daff28937acb4b27bb03c11d2875809a05347b2a248b1cb41cb62fb99379bc7232055692599cd0b4270cb18bf383ab2eaf132b132e9ad5ad0c1279cdb403e98ee0efa1c1cbeddda7245e0388decdf8f0a90008009450286e89ee672c09e92e28c58a4bf841a47338770101592a17e845af5d34277601f022cff6977f3e34be26e3d30664f78e6d3237ec327d8ce8d2acfdb87b012ab9c70c806764185419bb4b6f83e6f120728f2828a9be201634e5f3f6c1b91db597dbc0e8e488187fd7865dea55f14f62277993eaf9915f2946ffd44291af298142e71f6b4f4fc915aa9a0478013382179c7b0263c61e71567856778e38430c245659bb4e56245808c4f67572779509eb7d96636ab488b8658c7fac00fb252412dbdcd1d108f9e009e3624998c160fc62314c9915c59b3eb2d0f7a199c03f08b28ba7b68b3a88fee2e612221906df5101e57f080313e99a9a6ac2e9cd1bd70ff422fe2b5ad30b9d43a842c608d91e7282a3f0ab6a5b39f7bb44bd78492a8525e3e460e6dd4eb43131ac956d9db721432a4c1685f7679c39273b29f0ed60a513945782c23f6feb5072759a4b765bd624baae5f6799ffc60d6f30ea8856043a";

    /// @dev The batch-1 proof's public values. Bytes [32..96] carry that
    ///      batch's raw commitment, not the aggregator's binding digest.
    bytes internal constant BATCH_PUBLIC_VALUES =
        hex"2ec490cc1239f924eddc97fa13db1e4eee4124cdd85a15a1f518990d54f652d863c7606f00000000aee0ee9e00000000ff230fec00000000391e64c000000000c82a027700000000947973ce000000007f6f1c900000000088c821dd0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000e9414e134bb6945a148a79d44c8e850e5ef582a2b0e8dbfb2428ff0a515a6e66";

    /// @dev Real 2,208-byte BN254 pilfflonk SNARK of the aggregated range 1..4.
    bytes internal constant AGGREGATED_PROOF =
        hex"0b7466348ce4b3994070feb00fae1dd29ac7f622bd4476e99c0077f0808e5b3d274ae12bc7553653173075aa11680bdc6dc7635080245bb3fdd6d3560340a2e0158d7d9032cb3de30e55948e57e35ca8dfd541a2eeef68c4de39a94b15a8c9122b38d15826bb3f8ac6fbef51d93bb4f0bb9120dc161759425d997dbe4640c0df0b1fb59313d38e14d8f3894eb200ba3d09dd77b3c3774633ec69ec949bb8f7142cd16d51fa3828325efdf0d82e6e5fc33f47397c9e8df8fd466f3f91193ed80e1e063f777f940b54485775d3eaee8dc04dd3e69f0c049d05ade45bc13465b91b0d70b85e9532f9f13206d46d1dcf85921c976d2db70d15e715e56b2a02980b9226091e0184f6fd63163fdfb9c7ea1472c2088df02831a4c0dda80abb83f3179905eb4a43c348178a7c4f655478e8a5811a72ffde937699686b3b56100a6b792e0a037f7fc15498950e31f7027d7c20b0e8b1998123276d37d116a3794bcd38e6159c829bb520ed640c07378e4c3a8503eda532b8b7015e52bd9a32568ce57a98055069af255dd14fde411815d4aa6d872739c318e0fc68bf993e0018f0a4f78319620424b9b72f14f88700477cb62822bccfe881e4e9e6f3aa3f4252d65ef890130b153324a7a1ec9d1eef75b4a5e06cb536ac386128e0a3d22a1ad5af4a486b303fc2ce9684c444ab496a0b0b368aaec4f95d2b9efd436cb5ad69827ffad0510969a84db1bd81cc891d9dca82648e67f920bcc1fae2a0c708b2e80605ab6b4f18fb9152211dbb6b2d2ed126afcb52ac62c5af502320177b0a950724e4b39fc2138c6e75d4a6f5ab0326efb748c33d5dd94a4e2030d3710b745033267da5eca1018e6a4ff5634f6b862e2b1ab25683fe5141e4b84b097054276340a7a55aa03110aaf586261280a4221d112541cb9dfcc1c49252be3e4708e5e866a94f3ca5f20dda331e2747f0010051b4530cfae172579b4b0644e4e688dfd532823294ce3f1cd47497e65431d71d4f551b35b92a609c9a866925a81c565cae6526b6ac51161b1adb659198796d0fa4f92349fd60fe0dcb35b5342031877ddfaad2a6e45dab12a90268d25a4b0479a8485444ff6390007c878d89367008425de3553ab3d1090d0359edf75b41be51ad52f9e085ecd09114de03204aaccac9b068227eda5ee41bb9a949ea43a46f93fe25cc5c49e2fae404e9472bcdd2db93bc88003b24d65923ec63934dc8e418464e7b05d1fe30ed3408f2c3de05656c58dacb5a4945ef9217ada4eb413cf55aec787f81d0b443e7977b7c2e31b23f39398a038f5583964f00a745dc2fd6f2c481ec18a12fce027f96d0653e16b1f896ca8892ef826c660b1d4fb06276dd56beeeb8d06f7bb1aca89db6e5fe9486cb260c9383561b05aff014e97ca319bc2bffffebf3d50efdc9306fad60e00c5682fd8708f72205c920872f0b4dba58d70084a637ef1459e97f914ac5f9735e0096e72eec90da5635b1ac11631ef4d5e85771ff854a38efa7c6a59e3aef8bb24c152c22dbbbf449306cfd13bf8bbffcd86fa4bcb6c416e30cbd4804cf257f7cc10f60f5e1641c1ac005f4174a2a89817f0affd1d3545344a33f5dd9990c417d2206135b968850dfbbf4c30299f32acc59f777a9fa5a362961ccc91990ca030f6cda4305b4da29b91c23700992771dca9c3b2d2663bcb7c8f976e6a5a6cdd6d593efc3d8ff42d657d6dd6b0bb1e85dfae21b067f6b69f6f88b3b7397de37d02929f1a63aa672d1ecd8cac81bf149ee2de6779183483bbfe3734dd4ccbc299b52d46da8875f79a3e7c778ac2fb07da34e8e05f169b06e87d347986f88402b11e640bb33728414d9e3bdb4f52277fb679e18bdea12363fc1817b9becbb6a9fbdcabe4cbc25231c467f7762b81470d29a940b31de77415b07bc36d1ccd7de871a41e13e6ef62caf422c057b910b472c371cd44b386159a054d270f642111b49244f6205873d29c04c7b41bf6712e6da4e74b09bbc1f0c8c8cc402884d8ee9938e95ef89eeb726b06d08a318760bd26f794f95fdeaccabe8ead870bd1cc7b2828862dd0d78791b1dcc46268b1022fb60028259cea50e98183de0ed5bbc6962f30d4079d9a273209a455bf28d2514c628462a5bf2ac4097d87fcb00340d3c6c1c01960dcc166dd6b1623e5049ce039cbeffc2f8b62ff619c0ea9a98d055f79bc630cc11c96cfb0fd6829e3586b62df894c2b61b4b502c1053e7c52954444581db59874c2e1fba999f62c662a7f20518b6c3944357ed96d5d99882b9faa6102b65fa872cf834916aebbfdcf3351c10b069d7f83f4812147ca09da67c0447cbb356f62bd4f9f0118b8aa3712476722b2abf3d1737fcf8ca7490588562ab434fd3ea48c916331fe4019d6e135c83291a9c7d7973b00b83fe0dec57875e739441661022bad7a3d4ec2f40bbaa28e9f607f39c1508d20d71718f75a5cf973b5e50f79bc1187eac76c78ef8342203304b0bebcff6dfc449998f9cff04c50ae122b808e255d1e0761dbc2af0af47f433341ee5d30a71bf493e751eedb1836eba976f9cb7670de601cd5cfe4552ffd0f62d2d829df90af9b6da45573dd8f53c3fbe5c85c894f787310e9df720ce779c1066011afe4faf45de82be865a662cf1595da9506a8b21ae36758e7bbd486866f8cf1e3804f2838dffc3742bc7992bfc2c01a90675be6fc8af20b0818e5c2e93ffeb0317fb8db682292a4a97a36e624e2c6900d1f42a3ee20e8846511f5816afd22117b4698a4964651f82c46116844e418d09e0659a43f69c5e5ed3777790c585b61a4d019f9cf2bfbb294155836cf5ee0cd84635bee774567984f8600d7445e2990f7dae620103e0f0934309f61f9672c55f14c7369b96975a422a4a980f4310d52ee75cb0c4ee08543a59649ab0dec3efa1fb6462a0a32f4b56d5af01ceb56a4e2fbda1e945c470c781977f6387c62fe0faccee71f789ae1c21cd23ca7c2fbbe908106b21c7674e8d84a5ca2a539daad5aecfc5b84d1ffe41cb038080aa28b4760a9af116218af462fea127512313791916b4cd438b016e2f8e90ccae48fa93162208ef077dfe307e4d3b0e9f9449852d302d0d9cbf0aaca0dc40910571b8dfd6";

    /// @dev The aggregated proof's public values: the exact bytes
    ///      `ZiskVerifier.verify` reconstructs for this range.
    bytes internal constant AGGREGATED_PUBLIC_VALUES =
        hex"e7f72bf4c1825a6f852e65fc872c810320218c63ed41cf9bb4345737a4ac31ecb1449f7500000000ebc58ce2000000000243dd370000000074c8f1a60000000017b4e06d00000000f533c7e7000000004c2e8ced00000000c7bfb0b00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000e9414e134bb6945a148a79d44c8e850e5ef582a2b0e8dbfb2428ff0a515a6e66";

    /// @dev The four batch commitments the aggregated proof ingested, in batch
    ///      order. MultiProofRangeVectorTest pins the same vector.
    bytes32 internal constant COMMITMENT_1 = 0x63c7606faee0ee9eff230fec391e64c0c82a0277947973ce7f6f1c9088c821dd;
    bytes32 internal constant COMMITMENT_2 = 0x7d6a5ed6ffda210164c11dd6f6fccbd35c4ff70632e845a5bf256e3ec48940b9;
    bytes32 internal constant COMMITMENT_3 = 0xd5a7b4485d1aece18348655132e73c86b23fa0f251adb173f80123d05a914f15;
    bytes32 internal constant COMMITMENT_4 = 0xc5ed165443011bac65df4d0f4240de3429c033996e9fce630a631e117537cd61;

    /// @dev BN254 scalar field modulus (must equal ZiskVerifier._RFIELD).
    uint256 internal constant RFIELD = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    /// @dev Byte length of the ZiSK public-values preimage.
    uint256 internal constant PUBLIC_VALUES_BYTES = 576;
    /// @dev Word index of `rootCVadcopFinal`, public-values bytes [544..576].
    uint256 internal constant ROOT_C_WORD = 17;
    /// @dev Word index of the first all-zero guest-public slot, bytes [96..544].
    uint256 internal constant FIRST_ZERO_WORD = 3;
    /// @dev Proof word of the first opening evaluation. The words before it
    ///      are the eight G1 commitments.
    uint256 internal constant FIRST_EVALUATION_WORD = 16;

    ZiskVerifier internal ziskVerifier;

    function setUp() public {
        ziskVerifier = new ZiskVerifier(IZiskSnarkVerifier(address(new PilfflonkVerifier())));
    }

    /// @dev Load a 2,208-byte SNARK as the 69 words the SNARK verifier takes.
    function _proof69(bytes memory _proof) internal pure returns (bytes32[ZISK_SNARK_PROOF_LENGTH] memory words) {
        require(_proof.length == ZISK_SNARK_PROOF_LENGTH * 32, "proof length");
        for (uint256 i = 0; i < ZISK_SNARK_PROOF_LENGTH; i++) {
            bytes32 word;
            assembly {
                word := mload(add(add(_proof, 32), mul(i, 32)))
            }
            words[i] = word;
        }
    }

    /// @dev The same 69 words as the dynamic array `ZiskVerifier.verify` takes.
    function _proofWords(bytes memory _proof) internal pure returns (uint256[] memory words) {
        bytes32[ZISK_SNARK_PROOF_LENGTH] memory fixedWords = _proof69(_proof);
        words = new uint256[](ZISK_SNARK_PROOF_LENGTH);
        for (uint256 i = 0; i < ZISK_SNARK_PROOF_LENGTH; i++) {
            words[i] = uint256(fixedWords[i]);
        }
    }

    /// @dev Word `_index` of a public-values fixture.
    function _word(bytes memory _publicValues, uint256 _index) internal pure returns (bytes32 word) {
        assembly {
            word := mload(add(_publicValues, add(32, mul(_index, 32))))
        }
    }

    /// @dev A fixture's own single public signal.
    function _signal(bytes memory _publicValues) internal pure returns (uint256) {
        return uint256(sha256(_publicValues)) % RFIELD;
    }

    /// @dev The range's per-batch public inputs as the ZKsync OS lane passes
    ///      them: the untruncated batch commitments. `PUBLIC_INPUT_SHIFT`
    ///      applies once, inside the fold.
    function _rangePublicInputs() internal pure returns (uint256[] memory pis) {
        pis = new uint256[](4);
        pis[0] = uint256(COMMITMENT_1);
        pis[1] = uint256(COMMITMENT_2);
        pis[2] = uint256(COMMITMENT_3);
        pis[3] = uint256(COMMITMENT_4);
    }

    /// @dev The exposed wire-form pins are exactly the fixtures' public-values
    ///      bytes [0..32] and [544..576]; the pad bytes and the zero region the
    ///      reconstruction assumes are present in a real aggregated output; and
    ///      the VK hash commits to all three pins.
    function test_pinnedWireForms_and_layout() public view {
        assertEq(BATCH_PUBLIC_VALUES.length, PUBLIC_VALUES_BYTES, "batch fixture length");
        assertEq(AGGREGATED_PUBLIC_VALUES.length, PUBLIC_VALUES_BYTES, "aggregated fixture length");

        // The batch fixture is an inner state-transition proof, so its wire
        // [0..32] holds the inner pin; the aggregated proof attests to the
        // aggregator ELF, so its wire [0..32] holds the aggregator pin.
        assertEq(ziskVerifier.innerProgramVK(), _word(BATCH_PUBLIC_VALUES, 0), "innerProgramVK");
        assertEq(ziskVerifier.aggregatorProgramVK(), _word(AGGREGATED_PUBLIC_VALUES, 0), "aggregatorProgramVK");

        // One cargo-zisk setup produces both proofs, so both wires end with
        // the same vadcop-final root.
        assertEq(ziskVerifier.rootCVadcopFinal(), _word(BATCH_PUBLIC_VALUES, ROOT_C_WORD), "batch rootCVadcopFinal");
        assertEq(
            ziskVerifier.rootCVadcopFinal(),
            _word(AGGREGATED_PUBLIC_VALUES, ROOT_C_WORD),
            "aggregated rootCVadcopFinal"
        );

        // A guest public holds a 32-bit value, so the last four bytes of each
        // of the eight slots the digest occupies are pad.
        for (uint256 slot = 0; slot < 8; slot++) {
            for (uint256 offset = 4; offset < 8; offset++) {
                assertEq(AGGREGATED_PUBLIC_VALUES[32 + slot * 8 + offset], bytes1(0), "digest slot pad");
            }
        }

        // Reconstruction leaves bytes [96..544] zero; the aggregated fixture
        // confirms that region is zero in a real output.
        for (uint256 i = FIRST_ZERO_WORD; i < ROOT_C_WORD; i++) {
            assertEq(_word(AGGREGATED_PUBLIC_VALUES, i), bytes32(0), "zero region");
        }

        assertEq(
            keccak256(
                abi.encodePacked(
                    ziskVerifier.innerProgramVK(),
                    ziskVerifier.aggregatorProgramVK(),
                    ziskVerifier.rootCVadcopFinal()
                )
            ),
            ziskVerifier.verificationKeyHash(),
            "vk hash"
        );
    }

    /// @dev The production path over a real aggregated proof: ZiskVerifier
    ///      reconstructs the 576 public values from its pins and the range's
    ///      batch public inputs, then the vendored pilfflonk verifier checks the
    ///      pairing. Nothing here is mocked.
    function test_realAggregatedProof_reconstructedAndVerified() public view {
        assertTrue(
            ziskVerifier.verify(_rangePublicInputs(), _proofWords(AGGREGATED_PROOF)),
            "aggregated fixture must match the pins and the reconstruction"
        );
    }

    /// @dev A range that differs in one batch reconstructs a different digest,
    ///      hence a different signal, and the real pairing rejects it. This is
    ///      the cross-proof binding enforced by real crypto.
    function test_realAggregatedProof_tamperedRange_rejected() public view {
        uint256[] memory pis = _rangePublicInputs();
        pis[2] ^= 1;
        assertFalse(ziskVerifier.verify(pis, _proofWords(AGGREGATED_PROOF)));
    }

    /// @dev The vendored pilfflonk verifier accepts a real inner proof for its
    ///      own signal — anchoring the pairing, the sha256 field-reduction and
    ///      the preimage byte order on the per-batch side too.
    function test_realProof_fixtureSignal_accepts() public view {
        assertTrue(
            ziskVerifier.SNARK_VERIFIER().verifyProof(_proof69(BATCH_PROOF), [_signal(BATCH_PUBLIC_VALUES)]),
            "batch fixture must match the pilfflonk verification key"
        );
    }

    /// @dev Corrupting a proof scalar (an opening evaluation, still a valid
    ///      field element) makes the pairing fail.
    function test_realProof_tamperedSnark_rejected() public view {
        bytes32[ZISK_SNARK_PROOF_LENGTH] memory words = _proof69(BATCH_PROOF);
        words[FIRST_EVALUATION_WORD] ^= bytes32(uint256(1));
        assertFalse(ziskVerifier.SNARK_VERIFIER().verifyProof(words, [_signal(BATCH_PUBLIC_VALUES)]));
    }

    /// @dev Changing the public values changes the signal, so the proof is no
    ///      longer valid for it — the sha256 binding is sound.
    function test_realProof_tamperedPublicValues_rejected() public view {
        bytes memory tampered = BATCH_PUBLIC_VALUES;
        tampered[32] ^= 0x01; // flip a bit of word 1 (the commitment)
        assertFalse(ziskVerifier.SNARK_VERIFIER().verifyProof(_proof69(BATCH_PROOF), [_signal(tampered)]));
    }
}
