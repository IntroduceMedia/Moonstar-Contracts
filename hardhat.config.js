require('dotenv').config()
require('@nomiclabs/hardhat-ethers')
require("@nomiclabs/hardhat-etherscan");
require('@openzeppelin/hardhat-upgrades');

module.exports = {
  networks: {
    testnet: {
      url: process.env.NODE_URL,
      accounts: [process.env.PRIVATE_KEY]
    }
  },
  solidity: {
    compilers: [
      {
        version: '0.5.16'
      },
      {
        version: '0.6.12',
        settings: {
          optimizer: {
            enabled: true,
            runs: 200
          }
        }
      },
      {
        version: '0.8.3',
        settings: {
          optimizer: {
            enabled: true,
            runs: 200
          }
        }
      },
    ]
  },
  etherscan: {
    apiKey: "Y5HQ4K5GQ7Y4UPVJW4ZGWEZ59BIV4XWTFU"
  }
}
