import { expect } from "chai";
import type { Contract } from "zksync-ethers";
import { callFallback, deployContractYul } from "../shared/utils";
import { execSync } from "child_process";
import path from "path";

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

describe("EcAdd differential tests against eip-196 python implementation and go-ethereum precompile", function () {
  let ecAdd: Contract;

  before(async () => {
    ecAdd = await deployContractYul("EcAdd", "precompiles");

    // Build go binary `ecadd`
    execSync("go build -o ecadd ./cmd/ecadd", {
      cwd: "./test/ec_differential_tests/go",
    });
  });

  describe("Run specified test cases", function () {
    const testCases = [
      {
        input:
          "0x0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        description: "128 bytes: (1, 2) + (0, 0)",
      },
      {
        input:
          "0x0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        description: "128 bytes: (0, 0) + (0, 0)",
      },
      {
        input:
          "0x00000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000009000000000000000000000000000000000000000000000000000000000126198c000000000000000000000000000000000000000000000000000000000001e4dc",
        description: "128 bytes: (6, 9) + (19274124, 124124)",
      },
      {
        input:
          "0x0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        description: "128 bytes: (0, 0) + (0, 0)",
      },
      {
        input:
          "0x0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000002",
        description: "128 bytes: (0, 3) + (1, 2)",
      },
      {
        input:
          "0x0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000003",
        description: "128 bytes: (0, 0) + (1, 3)",
      },
      {
        input:
          "0x0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000002",
        description: "128 bytes: (0, 0) + (1, 2)",
      },
      {
        input:
          "0x0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000002",
        description: "128 bytes: (1, 2) + (1, 2)",
      },
      {
        input:
          "0x17c139df0efee0f766bc0204762b774362e4ded88953a39ce849a8a7fa163fa901e0559bacb160664764a357af8a9fe70baa9258e0b959273ffc5718c6d4cc7c17c139df0efee0f766bc0204762b774362e4ded88953a39ce849a8a7fa163fa92e83f8d734803fc370eba25ed1f6b8768bd6d83887b87165fc2434fe11a830cb",
        description: "128 bytes: (1074..1145, 8486..3932) + (1074..1145, 2103..4651)",
      },
      {
        input:
          "0x17c139df0efee0f766bc0204762b774362e4ded88953a39ce849a8a7fa163fa901e0559bacb160664764a357af8a9fe70baa9258e0b959273ffc5718c6d4cc7c039730ea8dff1254c0fee9c0ea777d29a9c710b7e616683f194f18c43b43b869073a5ffcc6fc7a28c30723d6e58ce577356982d65b833a5a5c15bf9024b43d98",
        description: "128 bytes: (1074..1145, 8486..3932) + (1624..2969, 3269..1336)",
      },
    ];

    testCases.forEach(({ input, description }) => {
      it(`should correctly handle ${description}`, async function () {
        const pythonResult = callPythonScript("./test/ec_differential_tests/python/EcAdd.py", [input]);
        const goResult = callGoScript("./test/ec_differential_tests/go/ecadd", [input]);

        // python and go results must match
        expect(goResult.success).to.be.equal(
          pythonResult.success,
          `Discrepancy between Go and Python results, input: ${input}`
        );
        expect(goResult.result).to.be.equal(
          pythonResult.result,
          `Discrepancy between Go and Python results, input: ${input}`
        );

        const call = callFallback(ecAdd, input);

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

  it("diff-fuzz(EcAdd)", async () => {
    const iterations = 20_000;

    for (let i = 0; i < iterations; i++) {
      console.log(`Iteration ${i + 1}/${iterations}`);

      const randomPointsResult = callPythonScript("./test/ec_differential_tests/python/EcHelper.py ecadd", []);

      if (!randomPointsResult.success) {
        throw new Error(randomPointsResult.error);
      }

      const input = randomPointsResult.result;

      const pythonResult = callPythonScript("./test/ec_differential_tests/python/EcAdd.py", [input]);
      const goResult = callGoScript("./test/ec_differential_tests/go/ecadd", [input]);

      // python and go results must match
      expect(goResult.success).to.be.equal(
        pythonResult.success,
        `Discrepancy between Go and Python results, input: ${input}`
      );
      expect(goResult.result).to.be.equal(
        pythonResult.result,
        `Discrepancy between Go and Python results, input: ${input}`
      );

      const call = callFallback(ecAdd, input);

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
