import { Wallet } from "ethers";
import {
  ANVIL_ACCOUNT2_ADDR,
  ANVIL_ACCOUNT2_PRIVATE_KEY,
  ANVIL_DEFAULT_PRIVATE_KEY,
  ANVIL_RECIPIENT_ADDR,
} from "./const";

export function isLiveInteropMode(): boolean {
  return process.env.ANVIL_INTEROP_LIVE === "1";
}

function getRequiredLiveEnv(name: string): string {
  const value = process.env[name]?.trim();
  if (!value) {
    throw new Error(`${name} is required when ANVIL_INTEROP_LIVE=1`);
  }
  return value;
}

export function getInteropTestPrivateKey(): string {
  return getInteropSourcePrivateKey();
}

export function getInteropSourcePrivateKey(): string {
  if (isLiveInteropMode()) {
    return getRequiredLiveEnv("LIVE_SOURCE_PRIVATE_KEY");
  }
  return process.env.ANVIL_INTEROP_PRIVATE_KEY?.trim() || ANVIL_DEFAULT_PRIVATE_KEY;
}

export function getInteropTestAddress(): string {
  return getInteropSourceAddress();
}

export function getInteropSourceAddress(): string {
  return new Wallet(getInteropTestPrivateKey()).address;
}

export function getInteropUnbundlerPrivateKey(): string {
  if (isLiveInteropMode()) {
    return getRequiredLiveEnv("LIVE_UNBUNDLER_PRIVATE_KEY");
  }
  return process.env.ANVIL_INTEROP_UNBUNDLER_PRIVATE_KEY?.trim() || ANVIL_ACCOUNT2_PRIVATE_KEY;
}

export function getInteropUnbundlerAddress(): string {
  return new Wallet(getInteropUnbundlerPrivateKey()).address;
}

function getConfiguredLiveAddress(addressEnv: string): string | undefined {
  const address = process.env[addressEnv]?.trim();
  if (address) {
    return address;
  }

  return undefined;
}

export function getInteropRecipientAddress(): string {
  if (isLiveInteropMode()) {
    return getConfiguredLiveAddress("LIVE_RECIPIENT_ADDRESS") || getInteropSourceAddress();
  }
  return ANVIL_RECIPIENT_ADDR;
}

export function getInteropSecondaryRecipientAddress(): string {
  if (isLiveInteropMode()) {
    const configured = getConfiguredLiveAddress("LIVE_SECONDARY_RECIPIENT_ADDRESS");
    if (configured) {
      return configured;
    }
    return getInteropUnbundlerAddress();
  }
  return ANVIL_ACCOUNT2_ADDR;
}
