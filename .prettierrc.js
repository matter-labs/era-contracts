module.exports = {
  ...require("@matterlabs/prettier-config"),
  plugins: ["prettier-plugin-solidity"],
  overrides: [
    {
      files: "*.sol",
      options: {
        bracketSpacing: false,
        printWidth: 120,
        singleQuote: false,
        tabWidth: 4,
        useTabs: false,
      },
    },
  ],
};
