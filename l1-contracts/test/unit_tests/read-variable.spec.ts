import { expect } from "chai";
import { readDynamicBytesFromSlots } from "../../scripts/read-variable-utils";

describe("read-variable dynamic bytes", function () {
  for (const length of [31, 32, 33, 63, 64, 65]) {
    it(`reads all ${length} bytes`, function () {
      const value = Array.from({ length }, (_, index) => index.toString(16).padStart(2, "0")).join("");
      const slots = Array.from({ length: Math.ceil(length / 32) }, (_, slotIndex) => {
        const start = slotIndex * 64;
        return `0x${value.slice(start, start + 64).padEnd(64, "0")}`;
      });

      expect(readDynamicBytesFromSlots(length, slots)).to.equal(`0x${value}`);
    });
  }
});
