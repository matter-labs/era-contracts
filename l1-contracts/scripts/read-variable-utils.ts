export function readDynamicBytesFromSlots(length: number, slots: string[]): string {
  let hex = "0x";
  for (let i = 0; i < slots.length; i++) {
    const bytesToRead = Math.min(32, length - i * 32);
    hex += slots[i].substr(2, bytesToRead * 2);
  }
  return hex;
}
