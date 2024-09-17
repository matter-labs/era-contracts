import { expect } from "chai";
import type { Contract } from "zksync-ethers";
import { callFallback, deployContractYul } from "../shared/utils";
import { execSync } from "child_process";
import path from "path";
import { randomBytes } from "crypto";

function callPythonScript(
  pathToScript: string,
  args: unknown[]
): { success: boolean; result: string; error_code: string; error: string } {
  try {
    const result = execSync(`python3 ${pathToScript} ${args.join(" ")}`);

    return JSON.parse(result.toString().trim());
  } catch (error) {
    console.error("Error calling Python script:", error);

    throw error;
  }
}

function callGoScript(
  scriptPath: string,
  args: unknown[]
): { success: boolean; result: string; error_code: string; error: string } {
  const scriptDir = path.dirname(scriptPath);
  const scriptName = path.basename(scriptPath);

  try {
    const result = execSync(`./${scriptName} ${args.join(" ")}`, {
      cwd: scriptDir,
      encoding: "utf8",
    });

    return JSON.parse(result.trim());
  } catch (error) {
    console.error("Error calling Go script:", error);
    throw error;
  }
}

function randomScalar(probability: number) {
  const randomValue = Math.random();

  // Check if the random value is less than the given probability
  if (randomValue < probability) {
    // Generate a value in the range [0, 1, 2]
    return Math.floor(Math.random() * 3)
      .toString(16)
      .padStart(64, "0");
  } else {
    // Generate random 32 byte scalar value
    return randomBytes(32).toString("hex");
  }
}

describe("EcMul differential tests against eip-196 python implementation and go-ethereum precompile", function () {
  let ecMul: Contract;

  before(async () => {
    ecMul = await deployContractYul("EcMul", "precompiles");

    // Build go binary
    execSync("go build -o ecmul ./cmd/ecmul", {
      cwd: "./test/ec_differential_tests/go",
    });
  });

  describe("Run specified test cases", function () {
    const testCases = [
      {
        input:
          "0x000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000",
        description: "96 bytes: (1, 2) * 0",
      },
    ];

    testCases.forEach(({ input, description }) => {
      it(`should correctly handle ${description}`, async function () {
        const pythonResult = callPythonScript("./test/ec_differential_tests/python/EcMul.py", [input]);
        const goResult = callGoScript("./test/ec_differential_tests/go/ecmul", [input]);

        // python and go results must match
        expect(goResult.success).to.be.equal(
          pythonResult.success,
          `Discrepancy between Go and Python results, input: ${input}`
        );
        expect(goResult.result).to.be.equal(
          pythonResult.result,
          `Discrepancy between Go and Python results, input: ${input}`
        );

        const call = callFallback(ecMul, input);

        if (pythonResult.success) {
          const returnData = await call;

          expect(returnData).to.be.equal(pythonResult.result);
        } else {
          switch (pythonResult.error_code) {
            case "NOT_ON_CURVE":
              // console.log("Point not on curve:", pythonResult.error);

              await expect(call).to.be.reverted;

              break;
            case "INVALID_INPUT":
              console.log("Invalid input:", pythonResult.error);
              throw new Error(pythonResult.error);

              break;
            default:
              console.log("Unknown error:", pythonResult.error);
              throw new Error(pythonResult.error);
          }
        }
      });
    });
  });

  it("diff-fuzz(EcMul)", async () => {
    const iterations = 10_000;

    for (let i = 0; i < iterations; i++) {
      console.log(`Iteration ${i + 1}/${iterations}`);

      const randomPointResult = callPythonScript("./test/ec_differential_tests/python/EcHelper.py ecmul", []);

      if (!randomPointResult.success) {
        throw new Error(randomPointResult.error);
      }

      // Generate random 32 byte scalar value
      const scalar = randomScalar(0.3); // 30% probability of generating a scalar in the range [0, 1, 2]

      const input = randomPointResult.result + scalar;

      const pythonResult = callPythonScript("./test/ec_differential_tests/python/EcMul.py", [input]);
      const goResult = callGoScript("./test/ec_differential_tests/go/ecmul", [input]);

      // python and go results must match
      expect(goResult.success).to.be.equal(
        pythonResult.success,
        `Discrepancy between Go and Python results, input: ${input}`
      );
      expect(goResult.result).to.be.equal(
        pythonResult.result,
        `Discrepancy between Go and Python results, input: ${input}`
      );

      const call = callFallback(ecMul, input);

      if (pythonResult.success) {
        const returnData = await call;

        expect(returnData).to.be.equal(pythonResult.result, `Failed for input: ${input}`);
      } else {
        switch (pythonResult.error_code) {
          case "NOT_ON_CURVE":
            // console.log("Point not on curve:", pythonResult.error);

            await expect(call).to.be.reverted;

            break;
          case "INVALID_INPUT":
            console.log(`Invalid input: ${input} - Error: `, pythonResult.error);
            throw new Error(pythonResult.error);

            break;
          default:
            console.log(`Unknown error for input: ${input} - Error: `, pythonResult.error);
            throw new Error(pythonResult.error);
        }
      }
    }
  }).timeout(0);
});
