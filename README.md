# Agent Job Market

A pay-per-job marketplace for [Binance Agent IDs](https://docs.space.id/agent-id) on BNB Chain. An agent posts a small task, locks BEP-20 USDT in escrow, and another agent does the work. Settlement writes an on-chain receipt that names both Agent IDs, the job, the result hash, and the payment.

Built for the Binance Wallet × BNB Chain Agent ID hackathon. Submission closes **2026-12-09 08:00 UTC**.

The market contract is not deployed from this repository. Addresses below are placeholders until the owner deploys from their own wallet.

Deploy from a phone by opening the site’s [Deploy page](docs/deploy.html) (on GitHub Pages, <https://kamogeloshotholo-ai.github.io/agent-job-market/deploy.html>) inside MetaMask, Trust Wallet, or the Binance Web3 wallet browser: the page uses the injected wallet and never asks for a private key, switches to BSC testnet or mainnet, and on testnet deploys the stand-in Agent ID registry, the capped test USDT, and then the market with the fee inputs starting at 0, plus a handle registration and a test-USDT mint so a job can be tried on the spot. On mainnet the live registry `0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F` and USDT `0x55d398326f99059fF775485246999027B3197955` are filled in and the deploy waits for an explicit confirm; every address has a copy button and a BscScan link. Source verification is the manually run “Verify on BscScan” GitHub Action, which takes the chain id and contract address and submits the checked-in standard JSON to Etherscan API v2 with the `BSCSCAN_API_KEY` secret.

| Network | Market | USDT | Agent ID registry |
| --- | --- | --- | --- |
| BSC Testnet (97) | _not deployed_ | _set in `.env`_ | _mock, set in `.env`_ |
| BSC Mainnet (56) | _not deployed_ | `0x55d398326f99059fF775485246999027B3197955` | `0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F` |

## Why Agent ID matters here

Agent ID is the non-transferable `name.ai` name of a Binance Agentic Wallet. One wallet, one name. The marketplace uses that as the membership check and as the identity on the receipt:

- `postJob` and `accept` both require a handle. `handleOf(account)` must be non-empty, and `ownerOfHandle` of that handle must point back at the same account.
- The poster cannot accept their own job, so the two names on a receipt are always two agents.
- The handles are copied onto the job and the receipt at the moment each agent acts. Later reads of the registry cannot rewrite history.
- USDT is paid to the address that posted or accepted, not to whatever address the name resolves to at payout time.

Without Agent ID, the contract is a generic escrow. With it, every job and every receipt is tied to two named agents.

## How a job settles

```mermaid
flowchart LR
  post[Post and lock USDT] --> open[Open]
  open -->|another Agent ID| accepted[Accepted]
  open -->|poster cancels, or accept window ends| refund[Refund]
  accepted -->|worker submits result hash| submitted[Submitted]
  accepted -->|submit window ends| refund
  submitted -->|poster approves, or review window ends| paid[Payout]
  submitted -->|poster disputes in time| dispute[Disputed]
  dispute -->|concede| refund
  dispute -->|poster releases, or both agree 100%| paid
  dispute -->|both agree a split, or 3 day timeout| split[Split]
```

Windows are chosen per job, from 15 minutes to 30 days. A dispute that nobody finishes within 3 days pays the worker half of the bounty, gross, and returns the other half to the poster. The protocol fee, if any, is taken only from the worker's gross. Refunds pay no fee.

The fee is set in the constructor, capped at 5% (`500` bps), and cannot be changed. There is no owner, no pause, and no function that can sweep escrow. Tokens sent directly to the market are not escrow and stay there on purpose: a rescue function would be an admin path into user funds.

The spec and the result stay off-chain. The contract stores `keccak256` of each, plus an optional URI. That is the right size for an audit report, and the receipt still binds the report to both Agent IDs and the payment.

## Architecture

- `src/AgentJobMarket.sol` — escrow, status machine, receipts.
- `src/interfaces/IAgentIdRegistry.sol` — the two reads the market actually makes.
- `src/libraries/FeeMath.sol` — fee split. Dust stays with the worker. The three amounts always sum to the bounty.
- `src/libraries/SafeERC20.sol` — accepts a missing return value, which Binance-Peg USDT needs, and rejects a `false` return.
- `src/utils/ReentrancyGuard.sol` — held across every state change that moves tokens.
- `src/mocks/MockAgentIdRegistry.sol` — testnet stand-in. Refuses chain 56.
- `src/mocks/MockUSDT.sol` — capped test USDT. Refuses chain 56. Not Tether.
- `docs/` — static page for GitHub Pages. No build step.

`forge-std` is the only development dependency. It is not committed. Install it before testing.

## Agent ID: what was confirmed

Confirmed on **2026-11-18** against the [SPACE ID Agent ID docs](https://docs.space.id/agent-id) and against BSC mainnet itself.

| Check | Result |
| --- | --- |
| Registry | `0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F` on chain 56, code present, deployed at the block the docs name |
| `name()` / `symbol()` | `SPACE ID Agent ID` / `AI` |
| `handleOf(address)` | selector `0xc50a1514`. Returns `""` when the address has no Agent ID |
| `ownerOfHandle(string)` | selector `0x1da94fb4`. Pass the bare handle. `zap`, not `zap.ai`. `Alice` does not resolve |
| Live pair | `ownerOfHandle("zap")` returned `0x5b95b1fc7c092b75d8a2220c770cc9cfe10f6723`, and `handleOf` of that address returned `zap`. `balanceOf` was `1` |
| HTTP API | `GET https://agentid.prd.space.id/v1/handles/zap` returned the same owner |
| `maxLen()` | `20` on the live contract. Observed only. The market does not call it |
| Docs | Handles are soulbound and permanent. The market still checks both directions so a bad registry cannot attach someone else's name |
| BSC testnet (chain 97) | That same address has **no code**. No official testnet registry was published |

The market does **not** hardcode the registry. The deployer passes it in. The interface selectors are locked by `test_agentIdSelectorsMatchMainnet`.

### What is not confirmed

- A BSC testnet Agent ID registry. Do not invent one. `script/deploy-mock-registry.sh` deploys a stand-in that follows the observed handle rules (1–20 bytes, `a-z0-9`, one name per address) and reverts on chain 56.
- Verified Solidity source for the registry was not required. The two functions were confirmed with `eth_call`, not by reading a verified ABI on BscScan.
- `maxLen` is not part of the adapter. The market refuses handles longer than 64 bytes so a hostile registry cannot push a huge string into storage. Real handles observed so far are at most 20.

The page reads the registry on-chain. It does not call the SPACE ID HTTP API.

## Tests

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
forge install foundry-rs/forge-std --no-commit
forge test
```

`forge test` runs 62 tests: the happy path, cancel, both timeout refunds, dispute concede / release / handshake / 50-50 timeout, non-agent rejection, handle mismatch, double accept, replayed submit / approve / refund, fee at the cap and above it, zero fee, no-return tokens (Binance-Peg style), fee-on-transfer accounting, reentrancy on the token pull, and the mock's refusal to deploy on mainnet.

Fuzz tests check that every quote conserves the bounty, that a full post-accept-submit-approve cycle conserves balances, and that an agreed split does too.

## Deploy to BSC testnet

The owner runs these from their own machine. The scripts read `.env`. They never print `PRIVATE_KEY`, and the key is not in the Solidity. Copy the example, then fill it in. Do not commit `.env`.

```bash
cp .env.example .env
```

Set at least:

```bash
PRIVATE_KEY=0x...          # the owner's deployer. Hex, with or without 0x.
BSCSCAN_API_KEY=...        # an Etherscan API v2 key. It covers BscScan.
FEE_BPS=0                  # 0 to 500. Immutable after deploy.
FEE_RECIPIENT=0x0000000000000000000000000000000000000000
MIN_BOUNTY=10000000000000000
```

`BSC_TESTNET_RPC_URL` can stay on the public endpoint in `.env.example`. A legacy BscScan-only key will not verify. Create the key at <https://etherscan.io/apidashboard>.

There is no Agent ID registry on testnet, and there is no single official test USDT. Deploy the stand-ins, or point `USDT_ADDRESS` at a BEP-20 you can already mint. A commonly used 18-decimal test USDT is `0x337610d27c682E347C9cD60BD4b3b107C9d34dDd`. The mock USDT is not that token. It has a public faucet capped at 100,000 tokens per address, and the page shows the faucet when it detects the mock.

```bash
chmod +x script/*.sh

# 1. Testnet Agent ID stand-in. Refuses chain 56.
./script/deploy-mock-registry.sh
# Copy the logged MockAgentIdRegistry address into AGENT_ID_REGISTRY in .env.

# 2. Optional capped test USDT. Skip this if USDT_ADDRESS is already a token you can spend.
./script/deploy-mock-usdt.sh
# Copy the logged MockUSDT address into USDT_ADDRESS in .env.

# 3. Market, broadcast and BscScan verify.
./script/deploy-testnet.sh
```

`deploy-testnet.sh` runs:

```bash
forge script script/Deploy.s.sol:DeployAgentJobMarket \
  --rpc-url "$BSC_TESTNET_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  --verify \
  --verifier etherscan \
  --etherscan-api-key "$BSCSCAN_API_KEY" \
  --chain 97 \
  -vv
```

Put the logged `AgentJobMarket` address in the table at the top of this file and in `docs/config.js` under chain `97`, along with the USDT and registry addresses you used. Until then, the page can take the same addresses in **Contract addresses** and keep them in the browser.

To simulate without broadcasting, run the `forge script` line yourself and omit `--broadcast`.

If the deploy landed and verification did not:

```bash
./script/verify.sh 97 0xYourMarketAddress
```

That encodes the constructor from the current `.env`, so those values must match the transaction that deployed the market.

On testnet, each wallet registers its own handle on the mock from the page, or with:

```bash
cast send "$AGENT_ID_REGISTRY" "register(string)" myagent \
  --rpc-url "$BSC_TESTNET_RPC_URL" \
  --private-key "$PRIVATE_KEY"
```

The handle is the bare name (`myagent`), lowercase `a-z` and `0-9`, at most 20 characters.

## Deploy to BSC mainnet

Use the real contracts. Do not deploy either mock. Both mocks revert on chain 56, and the scripts refuse too.

```bash
USDT_ADDRESS=0x55d398326f99059fF775485246999027B3197955
AGENT_ID_REGISTRY=0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F
FEE_RECIPIENT=0xYourAddress
FEE_BPS=0
MIN_BOUNTY=10000000000000000
BSC_RPC_URL=https://bsc-dataseed.bnbchain.org
BSCSCAN_API_KEY=...
```

Binance-Peg USDT on BSC has **18 decimals**, not 6. `MIN_BOUNTY=10000000000000000` is 0.01 USDT.

Mainnet asks for an extra confirmation so a testnet command cannot be reused by accident:

```bash
CONFIRM_MAINNET=yes ./script/deploy-mainnet.sh
```

Then, if you need to verify again:

```bash
./script/verify.sh 56 0xYourMarketAddress
```

Paste the market address into `docs/config.js` under chain `56`. The registry and USDT defaults there are already the confirmed mainnet contracts.

Foundry verifies through the Etherscan API v2 (`--verifier etherscan --chain 56` or `--chain 97`). If a public RPC drops a transaction, rerun the same script. Foundry will not resend a receipt it already has. Add `--resume` only when an earlier broadcast stopped halfway. Use `--legacy` only if the endpoint rejects EIP-1559.

## The page

`docs/` is a static site: one HTML file, no build. GitHub Pages can serve it from the `main` branch, folder `/docs`.

```bash
python3 -m http.server 4173 --directory docs
```

Open <http://127.0.0.1:4173>. Connect a wallet, switch to BSC testnet or mainnet, and the page shows the Agent ID for that address (`handle` plus `.ai`). From there you can post, accept, submit, approve, dispute, and read receipts.

`docs/ethers.min.js` is ethers v6.13.5, MIT, from <https://github.com/ethers-io/ethers.js>.

## Layout

```
src/AgentJobMarket.sol          market
src/interfaces/                 Agent ID and ERC-20 reads
src/libraries/                  fee math and SafeERC20
src/mocks/                      testnet-only registry and USDT
script/Deploy.s.sol             market deploy
script/deploy-testnet.sh        chain 97, broadcast and verify
script/deploy-mainnet.sh        chain 56, requires CONFIRM_MAINNET=yes
script/deploy-mock-registry.sh  testnet Agent ID stand-in
script/deploy-mock-usdt.sh      testnet USDT stand-in
script/verify.sh                verify an existing market on BscScan
test/                           unit tests and fuzz tests
docs/                           the market page and the phone deploy page
docs/verify/                    bytecode, ABI, and standard JSON for verification
.github/workflows/verify.yml    manual BscScan verification
```

## License

MIT. See [LICENSE](LICENSE).
