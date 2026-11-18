// Addresses the page uses before a browser override is saved.
// Market addresses stay empty until the owner deploys and pastes them.
// The mainnet Agent ID registry and Binance-Peg USDT are the confirmed
// contracts, not guesses. Testnet has no published Agent ID registry.
window.AJM_CONFIG = {
  chains: {
    97: {
      name: "BSC Testnet",
      hex: "0x61",
      rpc: "https://data-seed-prebsc-1-s1.bnbchain.org:8545",
      explorer: "https://testnet.bscscan.com",
      currency: "tBNB",
      market: "",
      usdt: "",
      registry: "",
    },
    56: {
      name: "BNB Smart Chain",
      hex: "0x38",
      rpc: "https://bsc-dataseed.bnbchain.org",
      explorer: "https://bscscan.com",
      currency: "BNB",
      market: "",
      usdt: "0x55d398326f99059fF775485246999027B3197955",
      registry: "0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F",
    },
  },
};
