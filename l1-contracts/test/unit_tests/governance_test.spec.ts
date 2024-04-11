import { expect } from "chai";
import type * as ethers from "ethers";
import * as hardhat from "hardhat";

import type { AdminFacetTest } from "../../typechain";
import { AdminFacetTestFactory, GovernanceFactory } from "../../typechain";

import { getCallRevertReason, randomAddress } from "./utils";

describe("Admin facet tests", function () {
  let adminFacetTest: AdminFacetTest;
  let randomSigner: ethers.Signer;

  before(async () => {
    const contractFactory = await hardhat.ethers.getContractFactory("AdminFacetTest");
    const contract = await contractFactory.deploy();
    adminFacetTest = AdminFacetTestFactory.connect(contract.address, contract.signer);

    const governanceContract = await contractFactory.deploy();
    const governance = GovernanceFactory.connect(governanceContract.address, governanceContract.signer);
    await adminFacetTest.setPendingAdmin(governance.address);

    randomSigner = (await hardhat.ethers.getSigners())[1];
  });

  it("StateTransitionManager successfully set validator", async () => {
    const validatorAddress = randomAddress();
    await adminFacetTest.setValidator(validatorAddress, true);

    const isValidator = await adminFacetTest.isValidator(validatorAddress);
    expect(isValidator).to.equal(true);
  });

  it("random account fails to set validator", async () => {
    const validatorAddress = randomAddress();
    const revertReason = await getCallRevertReason(
      adminFacetTest.connect(randomSigner).setValidator(validatorAddress, true)
    );
    expect(revertReason).equal("Hyperchain: not state transition manager");
  });

  it("StateTransitionManager successfully set porter availability", async () => {
    await adminFacetTest.setPorterAvailability(true);

    const porterAvailability = await adminFacetTest.getPorterAvailability();
    expect(porterAvailability).to.equal(true);
  });

  it("random account fails to set porter availability", async () => {
    const revertReason = await getCallRevertReason(adminFacetTest.connect(randomSigner).setPorterAvailability(false));
    expect(revertReason).equal("Hyperchain: not state transition manager");
  });

  it("StateTransitionManager successfully set priority transaction max gas limit", async () => {
    const gasLimit = "12345678";
    await adminFacetTest.setPriorityTxMaxGasLimit(gasLimit);

    const newGasLimit = await adminFacetTest.getPriorityTxMaxGasLimit();
    expect(newGasLimit).to.equal(gasLimit);
  });

  it("random account fails to priority transaction max gas limit", async () => {
    const gasLimit = "123456789";
    const revertReason = await getCallRevertReason(
      adminFacetTest.connect(randomSigner).setPriorityTxMaxGasLimit(gasLimit)
    );
    expect(revertReason).equal("Hyperchain: not state transition manager");
  });

  describe("change admin", function () {
    let newAdmin: ethers.Signer;

    before(async () => {
      newAdmin = (await hardhat.ethers.getSigners())[2];
    });

    it("set pending admin", async () => {
      const proposedAdmin = await randomSigner.getAddress();
      await adminFacetTest.setPendingAdmin(proposedAdmin);

      const pendingAdmin = await adminFacetTest.getPendingAdmin();
      expect(pendingAdmin).equal(proposedAdmin);
    });

    it("reset pending admin", async () => {
      const proposedAdmin = await newAdmin.getAddress();
      await adminFacetTest.setPendingAdmin(proposedAdmin);

      const pendingAdmin = await adminFacetTest.getPendingAdmin();
      expect(pendingAdmin).equal(proposedAdmin);
    });

    it("failed to accept admin from not proposed account", async () => {
      const revertReason = await getCallRevertReason(adminFacetTest.connect(randomSigner).acceptAdmin());
      expect(revertReason).equal("n4");
    });

    it("accept admin from proposed account", async () => {
      await adminFacetTest.connect(newAdmin).acceptAdmin();

      const admin = await adminFacetTest.getAdmin();
      expect(admin).equal(await newAdmin.getAddress());
    });
  });
});
