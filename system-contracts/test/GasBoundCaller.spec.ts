import type { SystemContext, GasBoundCallerTester } from "../typechain";
import { GasBoundCallerTesterFactory, SystemContextFactory } from "../typechain";
import {
  REAL_SYSTEM_CONTEXT_ADDRESS,
  TEST_GAS_BOUND_CALLER_ADDRESS,
  TEST_SYSTEM_CONTEXT_CONTRACT_ADDRESS,
} from "./shared/constants";
import { deployContractOnAddress, getWallets } from "./shared/utils";
import { ethers } from "hardhat";
import { expect } from "chai";
import { prepareEnvironment, setResult } from "./shared/mocks";

describe("GasBoundCaller tests", function () {
  let tester: GasBoundCallerTester;
  let systemContext: SystemContext;
  before(async () => {
    await prepareEnvironment();

    await deployContractOnAddress(TEST_GAS_BOUND_CALLER_ADDRESS, "GasBoundCallerTester");

    tester = GasBoundCallerTesterFactory.connect(TEST_GAS_BOUND_CALLER_ADDRESS, getWallets()[0]);

    const realSystemContext = SystemContextFactory.connect(REAL_SYSTEM_CONTEXT_ADDRESS, getWallets()[0]);
    // It is assumed that it never changes within tests, so we use the same as the real one
    const gasPerPubdata = await realSystemContext.gasPerPubdataByte();

    if (gasPerPubdata.eq(0)) {
      // If it is zero, some tests will start failing, so we need to double check.
      throw new Error("Gas per pubdata is 0, this is unexpected");
    }

    await setResult("SystemContext", "gasPerPubdataByte", [], {
      failure: false,
      returnData: ethers.utils.defaultAbiCoder.encode(["uint256"], [gasPerPubdata]),
    });

    systemContext = SystemContextFactory.connect(TEST_SYSTEM_CONTEXT_CONTRACT_ADDRESS, getWallets()[0]);
  });

  it("Test entry overhead", async () => {
    await (
      await tester.testEntryOverhead(ethers.constants.AddressZero, 1000000, 1000000, ethers.utils.randomBytes(10), {
        gasLimit: 80_000_000,
      })
    ).wait();
    const smallBytecodeGas = await tester.lastRecordedGasLeft();

    await (
      await tester.testEntryOverhead(ethers.constants.AddressZero, 1000000, 1000000, ethers.utils.randomBytes(100000), {
        gasLimit: 80_000_000,
      })
    ).wait();
    const bigBytecodeGas = await tester.lastRecordedGasLeft();

    // The results must be identical to ensure that the gas used does not depend on the size of the input
    expect(smallBytecodeGas).to.be.eql(bigBytecodeGas);
  });

  it("test returndata overhead", async () => {
    await (
      await tester.testReturndataOverhead(10, {
        gasLimit: 80_000_000,
      })
    ).wait();
    const smallBytecodeGas = await tester.lastRecordedGasLeft();

    await (
      await tester.testReturndataOverhead(100000, {
        gasLimit: 80_000_000,
      })
    ).wait();
    const bigBytecodeGas = await tester.lastRecordedGasLeft();

    // The results must be identical to ensure that the gas used does not depend on the size of the output
    expect(smallBytecodeGas).to.be.eql(bigBytecodeGas);
  });

  it("Should work correctly if gas provided is enough to cover both gas and pubdata", async () => {
    // This tx should succeed, since enough gas was provided to it
    await (
      await tester.gasBoundCall(tester.address, 80_000_000, tester.interface.encodeFunctionData("spender", [0, 100]), {
        gasLimit: 80_000_000,
      })
    ).wait();
  });

  it("Should work correctly if gas provided is not enough to cover both gas and pubdata", async () => {
    const pubdataToSend = 5000;
    const gasSpentOnPubdata = (await systemContext.gasPerPubdataByte()).mul(pubdataToSend);

    // Since we'll also spend some gas on execution, this tx should fail
    await expect(
      (
        await tester.gasBoundCallRelayer(
          gasSpentOnPubdata,
          tester.address,
          gasSpentOnPubdata,
          tester.interface.encodeFunctionData("spender", [0, pubdataToSend]),
          {
            gasLimit: 80_000_000,
          }
        )
      ).wait()
    ).to.be.rejected;
  });

  it("Should work correctly if maxGasToUse permits large pubdata usage", async () => {
    const pubdataToSend = 5000;
    const gasSpentOnPubdata = (await systemContext.gasPerPubdataByte()).mul(pubdataToSend);

    // Now while the execution gas wont be enoguh, we do allow to spend more just in case
    await (
      await tester.gasBoundCallRelayer(
        gasSpentOnPubdata,
        tester.address,
        80_000_000,
        tester.interface.encodeFunctionData("spender", [0, pubdataToSend]),
        {
          // Since we'll also spend some funds on execution, this
          gasLimit: 80_000_000,
        }
      )
    ).wait();
  });
});
