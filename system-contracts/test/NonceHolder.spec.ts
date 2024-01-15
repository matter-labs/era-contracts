
import { NonceHolder, NonceHolderFactory } from "../typechain";
import { TEST_NONCE_HOLDER_SYSTEM_CONTRACT_ADDRESS } from "./shared/constants";
import { prepareEnvironment } from "./shared/mocks";
import { deployContractOnAddress, getWallets } from "./shared/utils";

describe("NonceHolder tests", () => {
    const wallet = getWallets()[0];
    let nonceHolder: NonceHolder;

    before(async () => {
        await prepareEnvironment();
        deployContractOnAddress(TEST_NONCE_HOLDER_SYSTEM_CONTRACT_ADDRESS, "NonceHolder");
        nonceHolder = NonceHolderFactory.connect(TEST_NONCE_HOLDER_SYSTEM_CONTRACT_ADDRESS, wallet);
    })

    describe("getMinNonce", async () => {
        it("should get 1st account nonce", async () => {
            const minNonce = await nonceHolder.getMinNonce(wallet.address);
            console.log(minNonce);
            
        })

        
    })

    describe("getRawNonce", async () => {
      it("should get 1st account nonce", async () => {
        const rawNonce = await nonceHolder.getRawNonce(wallet.address);
        console.log(rawNonce);
      });
    })

    describe("getMinNonce", async () => {
      
    })

    describe("getMinNonce", async () => {
      
    })

});