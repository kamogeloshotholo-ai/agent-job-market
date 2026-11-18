"use strict";

const MAINNET_REGISTRY = "0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F";
const MAINNET_USDT = "0x55d398326f99059fF775485246999027B3197955";

const CHAINS = {
  97: {
    hex: "0x61",
    name: "BSC Testnet",
    currency: "tBNB",
    rpc: "https://data-seed-prebsc-1-s1.bnbchain.org:8545",
    explorer: "https://testnet.bscscan.com",
  },
  56: {
    hex: "0x38",
    name: "BNB Smart Chain",
    currency: "BNB",
    rpc: "https://bsc-dataseed.bnbchain.org",
    explorer: "https://bscscan.com",
  },
};

const state = {
  chainId: 0,
  user: "",
  signer: null,
  busy: false,
  artifacts: {},
  saved: { 97: {}, 56: {} },
};

const $ = (id) => document.getElementById(id);

function h(tag, props, children) {
  const node = document.createElement(tag);
  Object.entries(props || {}).forEach(([key, value]) => {
    if (value == null || value === false) return;
    if (key === "class") node.className = value;
    else if (key.startsWith("on") && typeof value === "function") node.addEventListener(key.slice(2).toLowerCase(), value);
    else node.setAttribute(key, String(value));
  });
  const list = Array.isArray(children) ? children : children == null ? [] : [children];
  list.forEach((child) => {
    if (child == null || child === false) return;
    node.append(child.nodeType ? child : document.createTextNode(String(child)));
  });
  return node;
}

function setStatus(text, isError) {
  const node = $("status");
  node.textContent = text || "";
  node.classList.toggle("error", Boolean(isError));
}

function explain(err) {
  const code = err && (err.code || err.error?.code);
  if (code === 4001 || code === "ACTION_REJECTED") return "The wallet closed the request. Nothing was sent.";
  const raw = err?.shortMessage || err?.reason || err?.message || "Something failed.";
  return String(raw).replace(/^execution reverted:?\s*/i, "").slice(0, 360);
}

function provider() {
  return window.ethereum || null;
}

function loadSaved() {
  for (const chainId of [97, 56]) {
    try {
      state.saved[chainId] = JSON.parse(localStorage.getItem("ajm.deploy." + chainId) || "{}");
    } catch {
      state.saved[chainId] = {};
    }
  }
}

function remember(chainId, key, address) {
  state.saved[chainId][key] = address;
  localStorage.setItem("ajm.deploy." + chainId, JSON.stringify(state.saved[chainId]));
  const prev = JSON.parse(localStorage.getItem("ajm.addresses." + chainId) || "{}");
  const bag = state.saved[chainId];
  localStorage.setItem("ajm.addresses." + chainId, JSON.stringify({
    market: bag.market || prev.market || "",
    usdt: bag.usdt || prev.usdt || "",
    registry: bag.registry || prev.registry || "",
  }));
  localStorage.setItem("ajm.chain", String(chainId));
}

async function copyText(text, button) {
  try {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      await navigator.clipboard.writeText(text);
    } else {
      throw new Error("no clipboard");
    }
  } catch {
    const input = document.createElement("textarea");
    input.value = text;
    input.setAttribute("readonly", "true");
    input.style.position = "fixed";
    input.style.left = "0";
    input.style.top = "0";
    input.style.fontSize = "16px";
    document.body.append(input);
    input.focus();
    input.select();
    input.setSelectionRange(0, text.length);
    const ok = document.execCommand("copy");
    input.remove();
    if (!ok) {
      setStatus("Select the address and copy it from the selection.", true);
      return;
    }
  }
  const previous = button.textContent;
  button.textContent = "Copied";
  setTimeout(() => { button.textContent = previous; }, 1200);
}

function addressCard(label, address) {
  const chain = CHAINS[state.chainId];
  const explorer = chain ? chain.explorer : "https://bscscan.com";
  const copy = h("button", { type: "button" }, "Copy");
  copy.addEventListener("click", () => copyText(address, copy));
  return h("div", { class: "stack" }, [
    h("strong", null, label),
    h("div", { class: "addr" }, address),
    h("div", { class: "row" }, [
      copy,
      h("a", { href: explorer + "/address/" + address, target: "_blank", rel: "noopener noreferrer" }, "BscScan"),
    ]),
  ]);
}

function paintWallet() {
  const chain = CHAINS[state.chainId];
  $("wallet").replaceChildren(
    h("div", { class: "stat" }, [h("span", null, "Wallet"), h("strong", null, state.user ? state.user.slice(0, 6) + "…" + state.user.slice(-4) : "Not connected")]),
    h("div", { class: "stat" }, [h("span", null, "Chain"), h("strong", null, chain ? chain.name : (state.chainId ? "Chain " + state.chainId : "—"))]),
  );
  $("connect").textContent = state.user ? "Wallet connected" : "Connect wallet";
  $("to-testnet").setAttribute("aria-pressed", state.chainId === 97 ? "true" : "false");
  $("to-mainnet").setAttribute("aria-pressed", state.chainId === 56 ? "true" : "false");
}

async function loadArtifacts() {
  const names = ["AgentJobMarket", "MockAgentIdRegistry", "MockUSDT"];
  await Promise.all(names.map(async (name) => {
    const [abiRes, binRes] = await Promise.all([
      fetch("./verify/" + name + ".abi.json"),
      fetch("./verify/" + name + ".bin"),
    ]);
    if (!abiRes.ok || !binRes.ok) throw new Error("Could not load the compiled " + name + " artifact.");
    const abi = await abiRes.json();
    const bin = (await binRes.text()).trim();
    state.artifacts[name] = { abi, bytecode: "0x" + bin.replace(/^0x/, "") };
  }));
}

async function connect() {
  const eth = provider();
  if (!eth) {
    setStatus("No wallet is injected. Open this page from MetaMask, Trust Wallet, or the Binance Web3 wallet browser.", true);
    return;
  }
  const browser = new ethers.BrowserProvider(eth);
  await browser.send("eth_requestAccounts", []);
  state.signer = await browser.getSigner();
  state.user = await state.signer.getAddress();
  state.chainId = Number((await browser.getNetwork()).chainId);
  paintWallet();
  render();
  if (!CHAINS[state.chainId]) {
    setStatus("This wallet is on chain " + state.chainId + ". Switch to BSC testnet or BSC mainnet.", true);
  } else {
    setStatus("Connected on " + CHAINS[state.chainId].name + ".");
  }
}

async function switchChain(chainId) {
  const eth = provider();
  if (!eth) {
    setStatus("No wallet is injected. Open this page inside the wallet app.", true);
    return;
  }
  const chain = CHAINS[chainId];
  try {
    await eth.request({ method: "wallet_switchEthereumChain", params: [{ chainId: chain.hex }] });
  } catch (err) {
    if (err && err.code === 4902) {
      await eth.request({
        method: "wallet_addEthereumChain",
        params: [{
          chainId: chain.hex,
          chainName: chain.name,
          nativeCurrency: { name: "BNB", symbol: chain.currency, decimals: 18 },
          rpcUrls: [chain.rpc],
          blockExplorerUrls: [chain.explorer],
        }],
      });
    } else {
      throw err;
    }
  }
  state.chainId = chainId;
  if (state.signer) {
    const browser = new ethers.BrowserProvider(eth);
    state.signer = await browser.getSigner();
    state.user = await state.signer.getAddress();
  }
  paintWallet();
  render();
  setStatus("Switched to " + chain.name + ".");
}

async function deploy(name, args, label) {
  if (state.busy) return null;
  if (!state.signer) {
    setStatus("Connect the wallet first.", true);
    return null;
  }
  if (!state.artifacts[name]) {
    setStatus("The compiled contract did not load. Reload this page and try again.", true);
    return null;
  }
  state.busy = true;
  setStatus("Confirm " + label + " in the wallet.");
  try {
    const art = state.artifacts[name];
    const factory = new ethers.ContractFactory(art.abi, art.bytecode, state.signer);
    const contract = await factory.deploy(...args);
    setStatus("Waiting for " + label + "…");
    const receipt = await contract.deploymentTransaction().wait();
    if (!receipt || receipt.status === 0) throw new Error(label + " reverted.");
    const address = await contract.getAddress();
    setStatus(label + " is at " + address);
    return address;
  } catch (err) {
    console.error(err);
    setStatus(explain(err), true);
    return null;
  } finally {
    state.busy = false;
  }
}

async function send(label, factory) {
  if (state.busy) return;
  if (!state.signer) {
    setStatus("Connect the wallet first.", true);
    return;
  }
  state.busy = true;
  setStatus("Confirm " + label + " in the wallet.");
  try {
    const tx = await factory();
    setStatus("Waiting for " + label + "…");
    const receipt = await tx.wait();
    if (!receipt || receipt.status === 0) throw new Error(label + " reverted.");
    setStatus(label + " confirmed.");
  } catch (err) {
    console.error(err);
    setStatus(explain(err), true);
  } finally {
    state.busy = false;
  }
}

function feeFrom(prefix) {
  const bpsRaw = $(prefix + "-fee").value.trim() || "0";
  if (!/^\d+$/.test(bpsRaw)) throw new Error("Fee must be a whole number from 0 to 500.");
  const bps = Number(bpsRaw);
  if (bps > 500) throw new Error("Fee is capped at 500 (5%).");
  let recipient = $(prefix + "-recipient").value.trim();
  if (bps === 0 && recipient === "") recipient = ethers.ZeroAddress;
  if (bps > 0 && recipient === "") recipient = state.user;
  if (!ethers.isAddress(recipient)) throw new Error("Fee recipient is not an address.");
  const minRaw = $(prefix + "-min").value.trim() || "0";
  let minBounty;
  try {
    minBounty = ethers.parseUnits(minRaw, 18);
  } catch {
    throw new Error("Minimum bounty must be a USDT amount, such as 0 or 0.01.");
  }
  return { bps, recipient: ethers.getAddress(recipient), minBounty };
}

function render() {
  captureDraft();
  const root = $("steps");
  root.replaceChildren();
  if (!provider()) {
    root.append(h("section", { class: "step" }, [
      h("h2", null, "Open it in the wallet"),
      h("p", { class: "hint" }, "This browser has no injected wallet. In MetaMask, Trust Wallet, or the Binance Web3 wallet, choose the dapp browser and open this same address."),
    ]));
    return;
  }
  if (state.chainId === 97) root.append(testnetPanel());
  else if (state.chainId === 56) root.append(mainnetPanel());
  else {
    root.append(h("section", { class: "step" }, [
      h("h2", null, "Choose BSC"),
      h("p", { class: "hint" }, "Switch to BSC testnet to rehearse with play tokens, or BSC mainnet to deploy against the live Agent ID registry."),
    ]));
  }
}

function testnetPanel() {
  const saved = state.saved[97];
  const wrap = h("div", { class: "steps" });

  const registrySlot = h("div", { id: "slot-registry" });
  if (saved.registry) registrySlot.append(addressCard("Test Agent ID registry", saved.registry));
  wrap.append(h("section", { class: "step" }, [
    h("h2", null, "1. Test Agent ID registry"),
    h("p", { class: "hint" }, "A stand-in so this phone can hold a name.ai on testnet. It is not the SPACE ID registry, and the contract refuses BSC mainnet."),
    registrySlot,
    h("button", { type: "button", class: "primary wide-btn", onclick: onDeployRegistry }, saved.registry ? "Deploy another registry" : "Deploy registry"),
  ]));

  const usdtSlot = h("div", { id: "slot-usdt" });
  if (saved.usdt) usdtSlot.append(addressCard("Test USDT", saved.usdt));
  wrap.append(h("section", { class: "step" }, [
    h("h2", null, "2. Test USDT"),
    h("p", { class: "hint" }, "18 decimals, with a faucet capped at 100,000 per address. Not Tether."),
    usdtSlot,
    h("button", { type: "button", class: "primary wide-btn", onclick: onDeployUsdt }, saved.usdt ? "Deploy another test USDT" : "Deploy test USDT"),
  ]));

  const marketSlot = h("div", { id: "slot-market" });
  if (saved.market) marketSlot.append(addressCard("Market", saved.market));
  wrap.append(h("section", { class: "step" }, [
    h("h2", null, "3. Market"),
    h("p", { class: "hint" }, "Wired to the registry and USDT from the steps above. Fee starts at 0. Deploy those two first."),
    feeFields("test"),
    marketSlot,
    h("button", { type: "button", class: "primary wide-btn", onclick: onDeployTestMarket }, "Deploy market"),
    saved.market ? h("a", { class: "pill-link", href: "./index.html" }, "Open the market") : null,
  ]));

  wrap.append(h("section", { class: "step" }, [
    h("h2", null, "4. Your test handle"),
    h("p", { class: "hint" }, "Lowercase letters and digits, 1 to 20 characters, no .ai suffix. It is registered to the connected address."),
    h("input", { id: "handle", maxlength: "20", autocomplete: "off", placeholder: "myagent" }),
    h("button", { type: "button", class: "primary wide-btn", onclick: onRegister }, "Register handle"),
  ]));

  wrap.append(h("section", { class: "step" }, [
    h("h2", null, "5. Test USDT for the demo"),
    h("p", { class: "hint" }, "Mints 1,000 test USDT to this wallet so you can post a job."),
    h("button", { type: "button", class: "primary wide-btn", onclick: onFaucet }, "Mint 1,000 test USDT"),
  ]));
  return wrap;
}

function mainnetPanel() {
  const saved = state.saved[56];
  const marketSlot = h("div", { id: "slot-market" });
  if (saved.market) marketSlot.append(addressCard("Market", saved.market));
  const box = h("input", { id: "mainnet-ok", type: "checkbox" });
  const button = h("button", { type: "button", class: "primary wide-btn", disabled: "true", onclick: onDeployMainMarket }, "Deploy market on mainnet");
  box.addEventListener("change", () => {
    if (box.checked) button.removeAttribute("disabled");
    else button.setAttribute("disabled", "true");
  });
  return h("div", { class: "steps" }, [
    h("section", { class: "step" }, [
      h("h2", null, "Live Agent ID and USDT"),
      h("p", { class: "hint" }, "These are the real contracts. They stay fixed on this page."),
      addressCard("Agent ID registry", MAINNET_REGISTRY),
      addressCard("Binance-Peg USDT", MAINNET_USDT),
    ]),
    h("section", { class: "step" }, [
      h("h2", null, "Deploy the market"),
      h("p", { class: "hint" }, "This spends BNB on BSC mainnet. The fee inputs start at 0, which means no protocol fee and no fee recipient."),
      feeFields("main"),
      h("label", { class: "confirm" }, [
        box,
        "I confirm this deploy is on BSC mainnet, against the live Agent ID registry and Binance-Peg USDT shown above.",
      ]),
      button,
      marketSlot,
      saved.market ? h("a", { class: "pill-link", href: "./index.html" }, "Open the market") : null,
    ]),
  ]);
}

function captureDraft() {
  for (const prefix of ["test", "main"]) {
    const fee = $(prefix + "-fee");
    if (!fee) continue;
    state.draft = state.draft || {};
    state.draft[prefix] = {
      fee: fee.value,
      recipient: $(prefix + "-recipient").value,
      min: $(prefix + "-min").value,
    };
  }
}

function feeFields(prefix) {
  const draft = (state.draft && state.draft[prefix]) || {};
  return h("div", { class: "stack" }, [
    h("label", null, ["Protocol fee, basis points (0 to 500)", h("input", { id: prefix + "-fee", inputmode: "numeric", value: draft.fee ?? "0" })]),
    h("label", null, ["Fee recipient, blank if the fee is 0", h("input", { id: prefix + "-recipient", autocomplete: "off", placeholder: "0x…", spellcheck: "false", value: draft.recipient || "" })]),
    h("label", null, ["Minimum bounty, USDT", h("input", { id: prefix + "-min", inputmode: "decimal", value: draft.min ?? "0" })]),
  ]);
}

async function onDeployRegistry() {
  if (state.chainId !== 97) return setStatus("Switch to BSC testnet first.", true);
  const address = await deploy("MockAgentIdRegistry", [], "the test registry");
  if (!address) return;
  remember(97, "registry", address);
  render();
}

async function onDeployUsdt() {
  if (state.chainId !== 97) return setStatus("Switch to BSC testnet first.", true);
  const address = await deploy("MockUSDT", [], "test USDT");
  if (!address) return;
  remember(97, "usdt", address);
  render();
}

async function onDeployTestMarket() {
  if (state.chainId !== 97) return setStatus("Switch to BSC testnet first.", true);
  const saved = state.saved[97];
  if (!saved.registry || !saved.usdt) {
    setStatus("Deploy the test registry and the test USDT first. The market is wired to those two.", true);
    return;
  }
  let fee;
  try { fee = feeFrom("test"); } catch (err) { setStatus(err.message, true); return; }
  const address = await deploy("AgentJobMarket", [saved.usdt, saved.registry, fee.recipient, fee.bps, fee.minBounty], "the market");
  if (!address) return;
  remember(97, "market", address);
  render();
}

async function onDeployMainMarket() {
  if (state.chainId !== 56) return setStatus("Switch to BSC mainnet first.", true);
  if (!$("mainnet-ok").checked) {
    setStatus("Confirm the mainnet deploy first.", true);
    return;
  }
  let fee;
  try { fee = feeFrom("main"); } catch (err) { setStatus(err.message, true); return; }
  const address = await deploy(
    "AgentJobMarket",
    [MAINNET_USDT, MAINNET_REGISTRY, fee.recipient, fee.bps, fee.minBounty],
    "the mainnet market",
  );
  if (!address) return;
  remember(56, "market", address);
  render();
}

async function onRegister() {
  if (state.chainId !== 97) return setStatus("Register the test handle on BSC testnet.", true);
  const registry = state.saved[97].registry;
  if (!registry) return setStatus("Deploy the test registry first.", true);
  const handle = $("handle").value.trim();
  if (!/^[a-z0-9]{1,20}$/.test(handle)) {
    setStatus("Use 1–20 characters, lowercase a–z and digits, with no .ai suffix.", true);
    return;
  }
  const contract = new ethers.Contract(registry, ["function register(string)"], state.signer);
  await send("handle registration", () => contract.register(handle));
}

async function onFaucet() {
  if (state.chainId !== 97) return setStatus("The faucet is on BSC testnet.", true);
  const usdt = state.saved[97].usdt;
  if (!usdt) return setStatus("Deploy the test USDT first.", true);
  const contract = new ethers.Contract(usdt, ["function faucet(uint256)"], state.signer);
  await send("the test USDT mint", () => contract.faucet(ethers.parseUnits("1000", 18)));
}

function bind() {
  $("connect").addEventListener("click", () => connect().catch((err) => setStatus(explain(err), true)));
  $("to-testnet").addEventListener("click", () => switchChain(97).catch((err) => setStatus(explain(err), true)));
  $("to-mainnet").addEventListener("click", () => switchChain(56).catch((err) => setStatus(explain(err), true)));
  const eth = provider();
  if (eth) {
    eth.on?.("chainChanged", () => window.location.reload());
    eth.on?.("accountsChanged", () => window.location.reload());
  }
}

async function boot() {
  if (!window.ethers) {
    setStatus("The page scripts did not load.", true);
    return;
  }
  loadSaved();
  bind();
  paintWallet();
  try {
    await loadArtifacts();
  } catch (err) {
    setStatus(explain(err), true);
  }
  const eth = provider();
  if (!eth) {
    render();
    setStatus("Open this page inside MetaMask, Trust Wallet, or the Binance Web3 wallet browser.", true);
    return;
  }
  try {
    const accounts = await eth.request({ method: "eth_accounts" });
    if (accounts && accounts.length) await connect();
    else {
      const hex = await eth.request({ method: "eth_chainId" });
      state.chainId = Number(hex);
      paintWallet();
      render();
    }
  } catch (err) {
    render();
    setStatus(explain(err), true);
  }
}

boot();
