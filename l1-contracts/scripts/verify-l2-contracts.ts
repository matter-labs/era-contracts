import fetch from "node-fetch";

// It includes all contracts being compiled
import BASE_REQUEST = require("./base-verification-request-v26.json");
import { sleep } from "zksync-ethers/build/utils";

export type HttpMethod = "POST" | "GET";

async function waitForVerificationResult(requestId: number) {
  let retries = 0;

  // eslint-disable-next-line no-constant-condition
  while (true) {
    if (retries > 500) {
      throw new Error("Too many retries");
    }

    const statusObject = await query("GET", `${VERIFICATION_URL}/${requestId}`);

    if (statusObject.status == "successful") {
      break;
    } else if (statusObject.status == "failed") {
      throw new Error(statusObject.error);
    } else {
      retries += 1;
      await sleep(1000);
    }
  }
}

/**
 * Performs an API call to the Contract verification API.
 *
 * @param endpoint API endpoint to call.
 * @param queryParams Parameters for a query string.
 * @param requestBody Request body. If provided, a POST request would be met and body would be encoded to JSON.
 * @returns API response parsed as a JSON.
 */
export async function query(
  method: HttpMethod,
  endpoint: string,
  queryParams?: { [key: string]: string },
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  requestBody?: any
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
): Promise<any> {
  const url = new URL(endpoint);
  // Iterate through query params and add them to URL.
  if (queryParams) {
    Object.entries(queryParams).forEach(([key, value]) => url.searchParams.set(key, value));
  }

  const init = {
    method,
    headers: {
      "Content-Type": "application/json",
    },
    body: JSON.stringify(requestBody),
  };
  if (requestBody) {
    init.body = JSON.stringify(requestBody);
  }

  const response = await fetch(url, init);
  try {
    return await response.clone().json();
  } catch (e) {
    throw {
      error: `Could not decode JSON in response: ${await response.text()}`,
      status: `${response.status} ${response.statusText}`,
    };
  }
}

const VERIFICATION_URL = process.env.VERIFICATION_URL!;

async function verifyContract(addr: string, fullName: string) {
  const requestClone = JSON.parse(JSON.stringify(BASE_REQUEST));
  requestClone.contractAddress = addr;
  requestClone.contractName = fullName;
  const result = await query("POST", VERIFICATION_URL, {}, requestClone);
  console.log(`Request for address ${addr} under id ${result}`);
  await waitForVerificationResult(result);
  console.log('Verification was successful.');
}

async function main() {
  await verifyContract(
    "0x0000000000000000000000000000000000010003",
    "contracts/bridge/asset-router/L2AssetRouter.sol:L2AssetRouter"
  );
  await verifyContract(
    "0x0000000000000000000000000000000000010004",
    "contracts/bridge/ntv/L2NativeTokenVault.sol:L2NativeTokenVault"
  );
  await verifyContract("0x0000000000000000000000000000000000010005", "contracts/bridgehub/MessageRoot.sol:MessageRoot");
  await verifyContract(
    "0x0000000000000000000000000000000000010007",
    "contracts/bridge/L2WrappedBaseToken.sol:L2WrappedBaseToken"
  );
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err.message || err);
    process.exit(1);
  });
