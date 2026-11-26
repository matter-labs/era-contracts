// solc ships no type declarations; the scripts use its standard JSON interface.
declare module "solc" {
  export function compile(input: string): string;
}
