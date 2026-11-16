import { expect } from "chai";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { getLastCompilationTime, needsRecompilation } from "../scripts/utils";

describe("Compilation timestamp", () => {
  let directory: string;

  beforeEach(() => {
    directory = fs.mkdtempSync(path.join(os.tmpdir(), "compilation-time-"));
  });

  afterEach(() => {
    fs.rmSync(directory, { recursive: true, force: true });
  });

  for (const value of ["", "not a timestamp", "999999999999999999999999999"]) {
    it(`recompiles when the timestamp is invalid: ${JSON.stringify(value)}`, () => {
      const timestamp = path.join(directory, "timestamp");
      fs.writeFileSync(timestamp, value);
      expect(getLastCompilationTime(timestamp)).to.equal(null);
      expect(needsRecompilation(directory, timestamp)).to.equal(true);
    });
  }

  it("preserves a valid cached timestamp", () => {
    const timestamp = path.join(directory, "timestamp");
    fs.writeFileSync(timestamp, "1700000000000");
    expect(getLastCompilationTime(timestamp)?.getTime()).to.equal(1700000000000);
  });
});
