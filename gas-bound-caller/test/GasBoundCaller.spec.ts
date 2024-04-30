import { REAL_SYSTEM_CONTEXT_ADDRESS } from "../../system-contracts/test/shared/constants";
import { deployContractOnAddress, getWallets } from "../../system-contracts/test/shared/utils";
import type { GasBoundCallerTester } from "../typechain";
import { GasBoundCallerTesterFactory } from "../typechain";
import type { ISystemContext } from "../typechain/ISystemContext";
import { ISystemContextFactory } from "../typechain/ISystemContextFactory";
import { expect } from "chai";

describe("GasBoundCaller tests", function () {
  let tester: GasBoundCallerTester;
  let systemContext: ISystemContext;
  before(async () => {
    // Note, that while the gas bound caller itself does not need to be in kernel space,
    // it does help a lot for easier testing, so the tester is in kernel space.
    const GAS_BOUND_CALLER_TESTER_ADDRESS = "0x000000000000000000000000000000000000ffff";
    await deployContractOnAddress(GAS_BOUND_CALLER_TESTER_ADDRESS, "GasBoundCallerTester");

    tester = GasBoundCallerTesterFactory.connect(GAS_BOUND_CALLER_TESTER_ADDRESS, getWallets()[0]);
    systemContext = ISystemContextFactory.connect(REAL_SYSTEM_CONTEXT_ADDRESS, getWallets()[0]);
  });

  it("Test entry overhead", async () => {
    await (
      await tester.testEntryOverhead(1000000, {
        gasLimit: 80_000_000,
      })
    ).wait();
    const smallBytecodeGas = await tester.lastRecordedGasLeft();

    await (
      await tester.testEntryOverhead(1000000, {
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
      await tester.gasBoundCall(
        tester.address,
        80_000_000,
        tester.interface.encodeFunctionData("spender", [0, 100, "0x"]),
        {
          gasLimit: 80_000_000,
        }
      )
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
          tester.interface.encodeFunctionData("spender", [0, pubdataToSend, "0x"]),
          "0x",
          gasSpentOnPubdata,
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

    // Now while the execution gas won't be enough, we do allow to spend more just in case
    await (
      await tester.gasBoundCallRelayer(
        gasSpentOnPubdata,
        tester.address,
        80_000_000,
        tester.interface.encodeFunctionData("spender", [0, pubdataToSend, "0x12345678"]),
        "0x12345678",
        gasSpentOnPubdata,
        {
          // Since we'll also spend some funds on execution, this
          gasLimit: 80_000_000,
        }
      )
    ).wait();
  });
});
