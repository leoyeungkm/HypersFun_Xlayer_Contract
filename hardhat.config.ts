import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@nomicfoundation/hardhat-verify";
import * as dotenv from "dotenv";
dotenv.config();

const XLAYER_PRIVATE_KEY = process.env.XLAYER_PRIVATE_KEY || "0x0000000000000000000000000000000000000000000000000000000000000001";
const OKLINK_API_KEY     = process.env.OKLINK_API_KEY     || "";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: { enabled: true, runs: 1 },
      viaIR: true,
      evmVersion: "cancun",
    },
  },
  networks: {
    xLayerMainnet: {
      url:      "https://rpc.xlayer.tech",
      chainId:  196,
      accounts: [XLAYER_PRIVATE_KEY],
    },
  },
  etherscan: {
    apiKey: {
      xLayerMainnet: OKLINK_API_KEY,
    },
    customChains: [
      {
        network: "xLayerMainnet",
        chainId: 196,
        urls: {
          apiURL:     "https://www.oklink.com/api/v5/explorer/contract/verify-source-code-plugin/XLAYER",
          browserURL: "https://www.oklink.com/xlayer",
        },
      },
    ],
  },
  sourcify: { enabled: false },
};

export default config;
