import {assert} from "chai";
import * as hardhat from "hardhat";
import {BlsTest, BlsTestFactory} from "../../typechain";
import * as ethers from "ethers";
import * as mcl from "./mcl"
import {parseG1, parseG2} from "./mcl"

describe("BLS tests", function () {
    let blsTest: BlsTest;

    before(async () => {
        await mcl.init();

        const blsTestFactory = await hardhat.ethers.getContractFactory("BLSTest");
        const blsTestContract = await blsTestFactory.deploy();
        blsTest = BlsTestFactory.connect(blsTestContract.address, blsTestContract.signer);
    });

    it("sqrt", async function () {
        const xx = "0x15f02a94241cdd85e8a6a736495868fcddbc159c7b5e58411f42ffc99e242859";
        const x = "0x1d1a8dc4d46768cbf211875a9b793160a757e8f932bcb00dbaad74896c48208d";

        const res = await blsTest.sqrt(xx);
        assert.equal(toHexString(res[0]), x);
        assert.isTrue(res[1]);
    });

    it("hash to point", async () => {
        const msg = "0x0102";
        const nonce = 0;
        const msgPointX = "0x22ae6da6b482f9b1b19b0b897c3fd43884180a1c5ee361e1107a1bc635649dda";
        const msgPointY = "0x247003094caa0bc0af26c755526f8a6a3fc0af2d56b126a95399be7df12b27d5";

        const res = await blsTest.hashToPoint(msg, nonce);
        assert.equal(toHexString(res[0]), msgPointX);
        assert.equal(toHexString(res[1]), msgPointY);
    });

    it("verifyAggregation: 2 signers", async function () {
        const msg = "0xbb";
        const nonce = 0;
        const pk2_agg = parseG2([
            "0x0c535050b30d2840426fddcdc60195d6ad86f6a6cd3eddca86db12981d00bc98",
            "0x1c671ec54097066a201fafdd81e5d3a60f3a191fdc6406fe41ce207e841bd4d7",
            "0x132721e9624c99c405d241c826c9f29580afc0b7248d7b306c238a094589d02d",
            "0x28471dbeef375addd57142a8934fbdfde17328c40ca522731570b211fbc1caed"
        ]);
        const pk1s = [
            parseG1([
                "0x205b6007b32ba25e9d7d57cd24a30232e1b988e94e3e2710cb93fb67f38d5342",
                "0x115ff84522167bd3acd0b1dde4d4cbb43393fae4acbee45a72bd0b96282c1713",
            ]),
            parseG1([
                "0x00245d648ef2355b51cb51611f06a162b057755a6b8711488b7172d7690ee697",
                "0x0f36a8afb1235056cc2886bfd6ca1415e66b2f918d3a15054b4f323457516188",
            ]),
        ]
        const sig = parseG1([
                "0x03508b0f269e2147c984e1c3a661a0757550724ba21d2ded2338d995dd60009e",
                "0x1f0d9750415f12350c7e04e0a456f1032d12c3d80ee456cac77130bd24479feb",
            ]
        );

        let res = await blsTest.verifyAggregation(
            pk1s.map(mcl.g1ToHex),
            mcl.g2ToHex(pk2_agg),
            mcl.g1ToHex(sig),
            msg,
            nonce,
        );
        assert.isTrue(res);
    });

    it("verifyAggregation: 3 signers", async function () {
        const msg = "0xbb";
        const nonce = 0;
        const pk1s = [
            parseG1([
                "0x205b6007b32ba25e9d7d57cd24a30232e1b988e94e3e2710cb93fb67f38d5342",
                "0x115ff84522167bd3acd0b1dde4d4cbb43393fae4acbee45a72bd0b96282c1713",
            ]),
            parseG1([
                "0x00245d648ef2355b51cb51611f06a162b057755a6b8711488b7172d7690ee697",
                "0x0f36a8afb1235056cc2886bfd6ca1415e66b2f918d3a15054b4f323457516188",
            ]),
            parseG1([
                "0x28d41611d5301be8c343fdb52880ecfb9127eb51ae8c180f3056405b98624f60",
                "0x1923bd9899ab51f3d65eee7caaa469af87d47678261a8ae74b61c3b4305212bd",
            ]),
        ]
        const pk2_agg = parseG2([
            "0x0b7238966012ce78268571ca9bc5560b9daf6759267439b841775f378fa3828f",
            "0x11b990358ad9e737552e946e81a494b78fa883c559f06b31a7698b3d406a02f3",
            "0x0aa6726b6aa6ee07026898094309f43fb1a766ebf845018691cfaf8f1baea576",
            "0x168de8b59899c556dc97a8a7312f8e82455911041c06cc26e389aae0432f41c3"
        ]);
        const sig = parseG1([
                "0x0a5273b46eaa3e9e7a1b15ca9d1a322eba765ebf169eed2d2c39de05177e7096",
                "0x2502e267a30d433c39b07861c51c574c9e19aa51a1d0577e97b20f59fd9cd096",
            ]
        );

        let res = await blsTest.verifyAggregation(
            pk1s.map(mcl.g1ToHex),
            mcl.g2ToHex(pk2_agg),
            mcl.g1ToHex(sig),
            msg,
            nonce,
        );
        assert.isTrue(res);
    });

    it("verifyAggregation: 4 signers", async function () {
        const msg = "0xbb";
        const nonce = 0;
        const pk1s = [
            parseG1([
                "0x205b6007b32ba25e9d7d57cd24a30232e1b988e94e3e2710cb93fb67f38d5342",
                "0x115ff84522167bd3acd0b1dde4d4cbb43393fae4acbee45a72bd0b96282c1713",
            ]),
            parseG1([
                "0x00245d648ef2355b51cb51611f06a162b057755a6b8711488b7172d7690ee697",
                "0x0f36a8afb1235056cc2886bfd6ca1415e66b2f918d3a15054b4f323457516188",
            ]),
            parseG1([
                "0x28d41611d5301be8c343fdb52880ecfb9127eb51ae8c180f3056405b98624f60",
                "0x1923bd9899ab51f3d65eee7caaa469af87d47678261a8ae74b61c3b4305212bd",
            ]),
            parseG1([
                "0x29d9b1049da1df8bb14ee1b09eda2e073c8202b87203b5241cd6c8b1bded117a",
                "0x1edbb89a55c79420b71b285274b4e5de9987524c853afd7f51973a3101888259",
            ]),
        ]
        const pk2_agg = parseG2([
            "0x1af2106069f0dea67f95fb1678ac4bc91f6db41891e537859eae9d913caf002e",
            "0x2e5098115cbc129f9b38f993b8f1ce03f971ad0f19088afe6e076298caa14a79",
            "0x10509abbb63f8327487f83a37383d698328940e0fb0b922078aabd5d338afa55",
            "0x0fd654a925d3adbcaa847aa7f646822d28f5b7601ba3ce749c1b02586ff08533"
        ]);
        const sig = parseG1([
                "0x24b9d4de0cdff11d75b08201929a8f1ba8c581b68d84424ad28f52f60a62c999",
                "0x0aed2acd336cdad4edea7e288af828ba96d1d617bbf76a84339dbdfd6307d97a",
            ]
        );

        let res = await blsTest.verifyAggregation(
            pk1s.map(mcl.g1ToHex),
            mcl.g2ToHex(pk2_agg),
            mcl.g1ToHex(sig),
            msg,
            nonce,
        );
        assert.isTrue(res);
    });
});

export function toHexString(bn: ethers.BigNumber): string {
    return ethers.utils.hexZeroPad(bn.toHexString(), 32)
}

