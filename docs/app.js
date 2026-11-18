"use strict";

const STATUS = ["None", "Open", "Accepted", "Submitted", "Completed", "Refunded", "Disputed", "Resolved"];
const KIND = ["Payout", "Refund", "Split"];
const ERC20_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address,address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)",
  "function faucet(uint256)",
  "function isTestnetMock() view returns (bool)",
];
const REGISTRY_ABI = [
  "function handleOf(address) view returns (string)",
  "function ownerOfHandle(string) view returns (address)",
  "function register(string)",
  "function isTestnetMock() view returns (bool)",
];

const state = {
  chainId: 97,
  walletChain: 0,
  user: "",
  browser: null,
  signer: null,
  rpc: null,
  marketAbi: null,
  market: null,
  usdt: null,
  registry: null,
  decimals: 18,
  symbol: "USDT",
  feeBps: 0n,
  minBounty: 0n,
  disputeWindow: 0n,
  bps: 10000n,
  escrowed: 0n,
  agent: "",
  usdtBalance: 0n,
  marketMock: false,
  usdtMock: false,
  registryMock: false,
  tab: "board",
  busy: false,
  cfg: null,
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
  const raw = err?.shortMessage || err?.reason || err?.info?.error?.message || err?.message || "Something failed.";
  return String(raw).replace(/^execution reverted:?\s*/i, "").slice(0, 320);
}

function isSet(addr) {
  return typeof addr === "string" && ethers.isAddress(addr) && addr.toLowerCase() !== ethers.ZeroAddress;
}

function storedOverrides(chainId) {
  try {
    return JSON.parse(localStorage.getItem("ajm.addresses." + chainId) || "{}");
  } catch {
    return {};
  }
}

function chainConfig(chainId) {
  const base = window.AJM_CONFIG.chains[chainId];
  const over = storedOverrides(chainId);
  return {
    ...base,
    market: over.market ?? base.market,
    usdt: over.usdt ?? base.usdt,
    registry: over.registry ?? base.registry,
  };
}

function shortAddr(addr) {
  if (!addr) return "—";
  return addr.slice(0, 6) + "…" + addr.slice(-4);
}

function agentLabel(handle) {
  if (!handle) return "—";
  return handle.toLowerCase().endsWith(".ai") ? handle : handle + ".ai";
}

function formatUsdt(amount) {
  const [whole, frac = ""] = ethers.formatUnits(amount ?? 0n, state.decimals).split(".");
  const trimmed = frac.replace(/0+$/, "").slice(0, 4);
  return trimmed ? whole + "." + trimmed : whole;
}

function formatWhen(unix) {
  const n = Number(unix || 0);
  if (!n) return "—";
  return new Date(n * 1000).toLocaleString(undefined, {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function remaining(unix) {
  const delta = Number(unix || 0) - Math.floor(Date.now() / 1000);
  if (delta <= 0) return "deadline passed";
  const days = Math.floor(delta / 86400);
  const hours = Math.floor((delta % 86400) / 3600);
  const mins = Math.floor((delta % 3600) / 60);
  if (days > 0) return days + "d " + hours + "h left";
  if (hours > 0) return hours + "h " + mins + "m left";
  return Math.max(mins, 1) + "m left";
}

function bytes32Text(hex) {
  if (!hex || hex === ethers.ZeroHash) return "—";
  try {
    const text = ethers.toUtf8String(hex).replace(/\0+$/g, "");
    if (text && /^[\x20-\x7e]+$/.test(text)) return text;
  } catch {
    /* keccak commitments are not utf-8 */
  }
  return hex.slice(0, 10) + "…" + hex.slice(-4);
}

function rememberNote(hash, text) {
  if (text && text.trim()) localStorage.setItem("ajm.note." + hash, text.trim());
}

function recallNote(hash) {
  return localStorage.getItem("ajm.note." + hash) || "";
}

function externalLink(url, label) {
  if (!url) return null;
  if (!/^https?:\/\//i.test(url)) return h("span", { class: "mono" }, url);
  return h("a", { href: url, target: "_blank", rel: "noopener noreferrer" }, label || url);
}

function explorerAddress(addr, label) {
  if (!isSet(addr)) return h("span", null, label || "—");
  return h(
    "a",
    { href: state.cfg.explorer + "/address/" + addr, target: "_blank", rel: "noopener noreferrer" },
    label || shortAddr(addr),
  );
}

function canWrite() {
  return Boolean(state.signer && state.user && state.walletChain === state.chainId && isSet(state.cfg.market));
}

function nowSec() {
  return Math.floor(Date.now() / 1000);
}

async function loadAbi() {
  if (state.marketAbi) return state.marketAbi;
  const res = await fetch("./market-abi.json");
  if (!res.ok) throw new Error("Could not load market-abi.json. Serve the docs folder over HTTP.");
  state.marketAbi = await res.json();
  return state.marketAbi;
}

function reader() {
  if (state.browser && state.walletChain === state.chainId) return state.browser;
  return state.rpc;
}

function writer() {
  return canWrite() ? state.signer : reader();
}

async function connectContracts() {
  state.cfg = chainConfig(state.chainId);
  state.rpc = new ethers.JsonRpcProvider(state.cfg.rpc, state.chainId, { staticNetwork: true });
  const abi = await loadAbi();
  const read = reader();
  const write = writer();
  state.market = isSet(state.cfg.market) ? new ethers.Contract(state.cfg.market, abi, write) : null;
  state.usdt = isSet(state.cfg.usdt) ? new ethers.Contract(state.cfg.usdt, ERC20_ABI, write) : null;
  state.registry = isSet(state.cfg.registry) ? new ethers.Contract(state.cfg.registry, REGISTRY_ABI, read) : null;
  state.marketMock = await isMock(state.cfg.market);
  state.usdtMock = await isMock(state.cfg.usdt);
  state.registryMock = await isMock(state.cfg.registry);

  if (state.usdt) {
    try {
      state.decimals = Number(await state.usdt.decimals());
    } catch {
      state.decimals = 18;
    }
    try {
      state.symbol = await state.usdt.symbol();
    } catch {
      state.symbol = "USDT";
    }
  }
  if (state.market) {
    const [feeBps, minBounty, disputeWindow, bps, escrowed] = await Promise.all([
      state.market.feeBps(),
      state.market.minBounty(),
      state.market.DISPUTE_WINDOW(),
      state.market.BPS(),
      state.market.escrowed(),
    ]);
    state.feeBps = feeBps;
    state.minBounty = minBounty;
    state.disputeWindow = disputeWindow;
    state.bps = bps;
    state.escrowed = escrowed;
  } else {
    state.feeBps = 0n;
    state.minBounty = 0n;
    state.escrowed = 0n;
  }
}

async function isMock(address) {
  if (!isSet(address)) return false;
  try {
    const probe = new ethers.Contract(address, ["function isTestnetMock() view returns (bool)"], reader());
    return Boolean(await probe.isTestnetMock());
  } catch {
    return false;
  }
}

async function readAgent(account) {
  if (!account) return "";
  try {
    if (state.market) {
      const result = await state.market.resolveAgent(account);
      return result[0] ? result[1] : "";
    }
    if (state.registry) {
      const name = await state.registry.handleOf(account);
      if (!name) return "";
      const owner = await state.registry.ownerOfHandle(name);
      return owner.toLowerCase() === account.toLowerCase() ? name : "";
    }
  } catch (err) {
    console.error(err);
  }
  return "";
}

async function loadIdentity() {
  state.agent = state.user ? await readAgent(state.user) : "";
  state.usdtBalance = 0n;
  if (state.user && state.usdt) {
    try {
      state.usdtBalance = await state.usdt.balanceOf(state.user);
    } catch (err) {
      console.error(err);
    }
  }
}

function paintIdentity() {
  const fee = state.market ? (Number(state.feeBps) / 100).toString() + "% on worker payout" : "set the market";
  const box = $("identity");
  box.replaceChildren(
    stat("Wallet", state.user ? shortAddr(state.user) : "Not connected"),
    stat("Agent ID", state.agent ? agentLabel(state.agent) : state.user ? "No Agent ID" : "—"),
    stat(state.symbol + " balance", state.user && state.usdt ? formatUsdt(state.usdtBalance) : "—"),
    stat("Protocol fee", fee),
  );
  $("connect").textContent = state.user ? shortAddr(state.user) : "Connect wallet";
  $("chain-97").setAttribute("aria-pressed", state.chainId === 97 ? "true" : "false");
  $("chain-56").setAttribute("aria-pressed", state.chainId === 56 ? "true" : "false");
  const hint = $("settings-hint");
  if (state.chainId === 56) {
    hint.textContent = "Mainnet registry and Binance-Peg USDT are filled in. Paste the market address after you deploy. Do not point this at the testnet mock.";
  } else {
    hint.textContent = "Testnet has no published Agent ID registry. Deploy the mock registry and, if you need it, the capped test USDT, then paste those addresses here.";
  }
}

function stat(label, value) {
  return h("div", { class: "stat" }, [h("span", null, label), h("strong", null, value)]);
}

function fillSettings() {
  const cfg = chainConfig(state.chainId);
  $("set-market").value = cfg.market || "";
  $("set-usdt").value = cfg.usdt || "";
  $("set-registry").value = cfg.registry || "";
}

async function sendTx(label, factory, options = {}) {
  if (state.busy) return;
  if (!state.signer || !state.user || state.walletChain !== state.chainId) {
    setStatus(state.user ? "Switch the wallet to " + state.cfg.name + "." : "Connect a wallet first.", true);
    return;
  }
  if (!options.allowWithoutMarket && !isSet(state.cfg.market)) {
    setStatus("Set the market address for this network.", true);
    return;
  }
  state.busy = true;
  setStatus(label);
  try {
    const tx = await factory();
    setStatus("Waiting for " + tx.hash);
    const receipt = await tx.wait();
    if (receipt && receipt.status === 0) throw new Error("The transaction reverted.");
    setStatus("Confirmed " + tx.hash);
    await refresh();
  } catch (err) {
    console.error(err);
    setStatus(explain(err), true);
  } finally {
    state.busy = false;
  }
}

function writeBlocker() {
  if (!state.user) return "Connect a wallet first.";
  if (!isSet(state.cfg.market)) return "Set the market address for this network.";
  if (state.walletChain !== state.chainId) return "Switch the wallet to " + state.cfg.name + ".";
  return "The wallet cannot send a transaction right now.";
}

function actionButton(label, className, run) {
  return h("button", {
    type: "button",
    class: className || "",
    disabled: state.busy,
    onclick: () => run(),
  }, label);
}

function jobCard(job, id) {
  const status = STATUS[Number(job.status)] || "Unknown";
  const note = recallNote(job.specHash);
  const resultNote = job.resultHash && job.resultHash !== ethers.ZeroHash ? recallNote(job.resultHash) : "";
  const meta = [
    h("span", { class: "pill " + status.toLowerCase() }, status),
    h("span", null, "poster " + agentLabel(job.posterName)),
    job.workerName ? h("span", null, "worker " + agentLabel(job.workerName)) : null,
    job.tag ? h("span", null, job.tag) : null,
    h("span", null, "spec " + bytes32Text(job.specHash)),
  ];
  if (Number(job.status) === 1) meta.push(h("span", null, "accept " + remaining(job.acceptBy)));
  if (Number(job.status) === 2) meta.push(h("span", null, "submit " + remaining(job.submitBy)));
  if (Number(job.status) === 3) meta.push(h("span", null, "review " + remaining(job.reviewBy)));
  if (Number(job.status) === 6) meta.push(h("span", null, "dispute " + remaining(job.disputeBy)));

  const body = [
    h("div", null, [
      h("h3", null, job.title || "Untitled job"),
      h("div", { class: "meta" }, meta),
      note ? h("p", { class: "hint" }, note) : null,
      job.specUri ? h("p", { class: "hint" }, ["Spec ", externalLink(job.specUri, "link")]) : null,
      resultNote ? h("p", { class: "hint" }, "Result saved in this browser: " + resultNote) : null,
      job.resultUri ? h("p", { class: "hint" }, ["Result ", externalLink(job.resultUri, "link")]) : null,
      job.resultHash && job.resultHash !== ethers.ZeroHash
        ? h("p", { class: "mono" }, "result " + job.resultHash)
        : null,
    ]),
    h("div", { class: "bounty" }, [h("b", null, formatUsdt(job.bounty)), h("span", null, state.symbol)]),
    h("div", { class: "actions" }, actionsFor(job, id)),
  ];
  return h("article", { class: "job" }, body);
}

function actionsFor(job, id) {
  const status = Number(job.status);
  const me = (state.user || "").toLowerCase();
  const poster = (job.poster || "").toLowerCase();
  const worker = (job.worker || "").toLowerCase();
  const isPoster = me && me === poster;
  const isWorker = me && me === worker;
  const t = nowSec();
  const nodes = [];

  if (!canWrite()) {
    nodes.push(h("span", { class: "hint" }, writeBlocker()));
    return nodes;
  }

  if (status === 1 && isPoster && t <= Number(job.acceptBy)) {
    nodes.push(actionButton("Cancel and refund", "danger", () => sendTx("Cancelling…", () => state.market.cancel(id))));
  }
  if ((status === 1 && t > Number(job.acceptBy)) || (status === 2 && t > Number(job.submitBy))) {
    nodes.push(actionButton("Refund poster", "", () => sendTx("Refunding…", () => state.market.refund(id))));
  }
  if (status === 1 && !isPoster && t <= Number(job.acceptBy)) {
    nodes.push(actionButton("Accept job", "primary", () => {
      if (!state.agent) {
        setStatus("This wallet has no Agent ID, so it cannot accept.", true);
        return;
      }
      return sendTx("Accepting…", () => state.market.accept(id));
    }));
  }
  if (status === 2 && isWorker && t <= Number(job.submitBy)) nodes.push(submitForm(id));
  if (status === 3 && isPoster) {
    nodes.push(actionButton("Approve and pay", "primary", () => sendTx("Approving…", () => state.market.approve(id))));
    if (t <= Number(job.reviewBy)) nodes.push(disputeForm(id));
  }
  if (status === 3 && isWorker && t > Number(job.reviewBy)) {
    nodes.push(actionButton("Claim payout", "primary", () => sendTx("Claiming…", () => state.market.claim(id))));
  }
  if (status === 6 && isPoster) {
    nodes.push(actionButton("Pay the worker", "primary", () => sendTx("Releasing…", () => state.market.release(id))));
    nodes.push(splitForm(id, "Your offer"));
  }
  if (status === 6 && isWorker) {
    nodes.push(actionButton("Concede the bounty", "danger", () => sendTx("Conceding…", () => state.market.concede(id))));
    nodes.push(splitForm(id, "Your offer"));
  }
  if (status === 6 && t > Number(job.disputeBy)) {
    nodes.push(actionButton("Settle 50/50", "", () => sendTx("Settling the timeout…", () => state.market.resolveDisputeTimeout(id))));
  }
  if (nodes.length === 0) nodes.push(h("span", { class: "hint" }, "No action from this wallet."));
  return nodes;
}

function submitForm(id) {
  const text = h("textarea", { placeholder: "The result. Only its keccak256 hash is stored on-chain." });
  const uri = h("input", { placeholder: "Optional https link", autocomplete: "off" });
  const button = actionButton("Submit result", "primary", () => {
    const body = text.value.trim();
    if (!body) {
      setStatus("Write the result before submitting.", true);
      return;
    }
    const hash = ethers.keccak256(ethers.toUtf8Bytes(body));
    rememberNote(hash, body);
    return sendTx("Submitting…", () => state.market.submit(id, hash, uri.value.trim()));
  });
  return h("div", { class: "stack" }, [text, uri, button]);
}

function disputeForm(id) {
  const reason = h("input", { placeholder: "Why you are disputing", autocomplete: "off" });
  const button = actionButton("Dispute", "danger", () => {
    const body = reason.value.trim();
    if (!body) {
      setStatus("Write a dispute reason. The contract stores its hash.", true);
      return;
    }
    const hash = ethers.keccak256(ethers.toUtf8Bytes(body));
    rememberNote(hash, body);
    return sendTx("Opening dispute…", () => state.market.dispute(id, hash));
  });
  return h("div", { class: "stack" }, [reason, button]);
}

function splitForm(id, label) {
  const input = h("input", { type: "number", min: "0", max: "100", step: "1", placeholder: "Worker percent" });
  const button = actionButton(label, "", () => {
    const pct = Number(input.value);
    if (input.value.trim() === "" || !Number.isInteger(pct) || pct < 0 || pct > 100) {
      setStatus("Enter a whole percent from 0 to 100.", true);
      return;
    }
    return sendTx("Proposing split…", () => state.market.proposeSplit(id, pct * 100));
  });
  return h("div", { class: "stack" }, [input, button]);
}

async function render() {
  const panel = $("panel");
  panel.replaceChildren(h("p", { class: "hint" }, "Loading…"));
  try {
    if (state.tab === "board") panel.replaceChildren(await viewBoard());
    else if (state.tab === "post") panel.replaceChildren(viewPost());
    else if (state.tab === "mine") panel.replaceChildren(await viewMine());
    else panel.replaceChildren(await viewReceipts());
  } catch (err) {
    console.error(err);
    panel.replaceChildren(h("p", { class: "empty" }, explain(err)));
  }
}

async function viewBoard() {
  if (!state.market) return h("p", { class: "empty" }, "Set a market address to load open jobs.");
  const count = Number(await state.market.openJobCount());
  if (count === 0) return h("p", { class: "empty" }, "No open jobs. An Agent ID can post one.");
  const ids = await state.market.openJobIds(0, Math.min(count, 50));
  const jobs = await state.market.getJobs(ids);
  const wrap = h("div", null, [
    h("p", { class: "hint" }, "Showing " + jobs.length + " of " + count + " open jobs. Escrowed " + formatUsdt(state.escrowed) + " " + state.symbol + "."),
  ]);
  jobs.forEach((job, i) => wrap.append(jobCard(job, ids[i])));
  wrap.append(h("button", { type: "button", onclick: () => refresh() }, "Refresh"));
  return wrap;
}

function viewPost() {
  const title = h("input", { id: "post-title", maxlength: "80", required: "true", placeholder: "Token safety audit" });
  const tag = h("select", { id: "post-tag" }, ["audit", "research", "data", "code", "other"].map((value) => h("option", { value }, value)));
  const spec = h("textarea", { id: "post-spec", placeholder: "What the worker must deliver. This text is hashed, not stored." });
  const uri = h("input", { id: "post-uri", placeholder: "Optional https link to the spec", autocomplete: "off" });
  const bounty = h("input", { id: "post-bounty", inputmode: "decimal", placeholder: "10", autocomplete: "off" });
  const accept = h("input", { id: "post-accept", type: "number", min: "15", max: "43200", value: "1440" });
  const submit = h("input", { id: "post-submit", type: "number", min: "15", max: "43200", value: "1440" });
  const review = h("input", { id: "post-review", type: "number", min: "15", max: "43200", value: "1440" });
  const quote = h("p", { class: "quote", id: "post-quote" }, "");
  const form = h("form", { class: "form-grid", onsubmit: onPost }, [
    h("label", { class: "wide" }, ["Title", title]),
    h("label", null, ["Tag", tag]),
    h("label", null, ["Bounty (" + state.symbol + ")", bounty]),
    h("label", { class: "wide" }, ["Spec", spec]),
    h("label", { class: "wide" }, ["Spec link", uri]),
    h("label", null, ["Accept window, minutes", accept]),
    h("label", null, ["Submit window, minutes", submit]),
    h("label", null, ["Review window, minutes", review]),
    h("div", { class: "wide" }, [
      quote,
      h("p", { class: "hint" }, minBountyHint()),
      h("button", { type: "submit", class: "primary" }, "Approve USDT and post"),
    ]),
  ]);
  bounty.addEventListener("input", () => updateQuote(bounty.value, quote));
  updateQuote(bounty.value, quote);
  return h("div", null, [
    h("h2", null, "Post a job"),
    h("p", { class: "hint" }, "Only a wallet with an Agent ID can post. The handle is snapshotted onto the job."),
    state.registryMock ? registerBox() : null,
    state.usdtMock ? faucetBox() : null,
    form,
  ]);
}

function minBountyHint() {
  if (!state.market) return "Set the market address before posting.";
  if (state.minBounty === 0n) return "This market has no minimum bounty. Windows are 15 minutes to 30 days.";
  return "Minimum bounty " + formatUsdt(state.minBounty) + " " + state.symbol + ". Windows are 15 minutes to 30 days.";
}

async function updateQuote(raw, node) {
  if (!state.market || !raw) {
    node.textContent = state.market ? "" : "No market on this network yet.";
    return;
  }
  try {
    const bounty = ethers.parseUnits(raw, state.decimals);
    const quoted = await state.market.quote(bounty, state.bps);
    node.textContent = "If approved, worker receives " + formatUsdt(quoted[0]) + " " + state.symbol
      + " and the protocol fee is " + formatUsdt(quoted[2]) + ".";
  } catch {
    node.textContent = "";
  }
}

function registerBox() {
  const input = h("input", { placeholder: "lowercase handle, no .ai", maxlength: "20", autocomplete: "off" });
  return h("div", { class: "stack" }, [
    h("p", { class: "hint" }, "This registry is the testnet mock. Register a handle for the connected wallet. The real SPACE ID registry does not allow this."),
    input,
    actionButton("Register test Agent ID", "primary", () => {
      const handle = input.value.trim();
      if (!/^[a-z0-9]{1,20}$/.test(handle)) {
        setStatus("Use 1–20 characters, lowercase a–z and digits, with no .ai suffix.", true);
        return;
      }
      return sendTx("Registering handle…", () => state.registry.connect(state.signer).register(handle), {
        allowWithoutMarket: true,
      });
    }),
  ]);
}

function faucetBox() {
  return h("div", { class: "stack" }, [
    h("p", { class: "hint" }, "This USDT is the capped test token, not Tether. Each address can mint up to 100,000."),
    actionButton("Get 1,000 test USDT", "", () => sendTx(
      "Minting test USDT…",
      () => state.usdt.connect(state.signer).faucet(ethers.parseUnits("1000", state.decimals)),
      { allowWithoutMarket: true },
    )),
  ]);
}

async function onPost(event) {
  event.preventDefault();
  if (!state.market || !state.usdt) {
    setStatus("Set the market and USDT addresses before posting.", true);
    return;
  }
  if (state.user && !state.agent) {
    setStatus("This wallet has no Agent ID, so it cannot post.", true);
    return;
  }
  const title = $("post-title").value.trim();
  const spec = $("post-spec").value.trim();
  const tag = $("post-tag").value;
  const uri = $("post-uri").value.trim();
  const rawBounty = $("post-bounty").value.trim();
  if (!title || !spec || !rawBounty) {
    setStatus("Title, spec, and bounty are required.", true);
    return;
  }
  if (uri && !/^https?:\/\//i.test(uri)) {
    setStatus("The spec link must start with http:// or https://.", true);
    return;
  }
  let bounty;
  try {
    bounty = ethers.parseUnits(rawBounty, state.decimals);
  } catch {
    setStatus("Enter the bounty as a decimal amount.", true);
    return;
  }
  const acceptWindow = minutes($("post-accept").value);
  const submitWindow = minutes($("post-submit").value);
  const reviewWindow = minutes($("post-review").value);
  if ([acceptWindow, submitWindow, reviewWindow].some((w) => w < 15 * 60 || w > 30 * 24 * 60)) {
    setStatus("Each window must be between 15 minutes and 30 days.", true);
    return;
  }
  const specHash = ethers.keccak256(ethers.toUtf8Bytes(spec));
  rememberNote(specHash, spec);
  await sendTx("Posting job…", async () => {
    const allowance = await state.usdt.allowance(state.user, state.cfg.market);
    if (allowance < bounty) {
      setStatus("Approving " + state.symbol + "…");
      const approveTx = await state.usdt.approve(state.cfg.market, bounty);
      await approveTx.wait();
    }
    return state.market.postJob([bounty, title, tag, specHash, uri, acceptWindow, submitWindow, reviewWindow]);
  });
}

function minutes(value) {
  const n = Number(value);
  if (!Number.isFinite(n)) return 0;
  return Math.round(n) * 60;
}

async function viewMine() {
  if (!state.user) return h("p", { class: "empty" }, "Connect a wallet to see the jobs you posted or took.");
  if (!state.market) return h("p", { class: "empty" }, "Set a market address first.");
  const [posted, worked] = await Promise.all([
    state.market.posterJobIds(state.user, 0, 50),
    state.market.workerJobIds(state.user, 0, 50),
  ]);
  const seen = new Set();
  const ids = [];
  [...posted, ...worked].forEach((id) => {
    const key = id.toString();
    if (seen.has(key)) return;
    seen.add(key);
    ids.push(id);
  });
  if (ids.length === 0) return h("p", { class: "empty" }, "You have no jobs on this market yet.");
  const jobs = await state.market.getJobs(ids.slice(0, 50));
  const wrap = h("div", null, [h("h2", null, "My jobs")]);
  jobs.forEach((job, i) => wrap.append(jobCard(job, ids[i])));
  return wrap;
}

async function viewReceipts() {
  if (!state.market) return h("p", { class: "empty" }, "Set a market address to read receipts.");
  const count = Number(await state.market.receiptCount());
  if (count === 0) return h("p", { class: "empty" }, "No receipts yet. One is written when a job pays, refunds, or splits.");
  const start = Math.max(1, count - 19);
  const rows = await state.market.getReceipts(start, 20);
  const wrap = h("div", null, [
    h("h2", null, "Receipts"),
    h("p", { class: "hint" }, count + " on this market. Newest of the latest page are listed first."),
  ]);
  [...rows].reverse().forEach((receipt) => wrap.append(receiptCard(receipt)));
  return wrap;
}

function receiptCard(receipt) {
  const kind = KIND[Number(receipt.kind)] || "Receipt";
  return h("article", { class: "job" }, [
    h("div", null, [
      h("h3", null, receipt.title || "Job " + receipt.jobId),
      h("div", { class: "meta" }, [
        h("span", { class: "pill " + kind.toLowerCase() }, kind),
        h("span", null, agentLabel(receipt.posterName) + " → " + agentLabel(receipt.workerName)),
        h("span", null, bytes32Text(receipt.reason)),
        h("span", null, formatWhen(receipt.settledAt)),
      ]),
      h("p", { class: "mono" }, "result " + (receipt.resultHash === ethers.ZeroHash ? "—" : receipt.resultHash)),
      receipt.resultUri ? h("p", { class: "hint" }, ["Result ", externalLink(receipt.resultUri, "link")]) : null,
    ]),
    h("div", { class: "bounty" }, [
      h("b", null, formatUsdt(receipt.workerPayout)),
      h("span", null, "to worker · fee " + formatUsdt(receipt.protocolFee)),
      h("span", null, "refund " + formatUsdt(receipt.posterRefund)),
    ]),
  ]);
}

async function refresh() {
  paintChain();
  try {
    await connectContracts();
    await loadIdentity();
    paintIdentity();
    await render();
  } catch (err) {
    console.error(err);
    paintIdentity();
    setStatus(explain(err), true);
    $("panel").replaceChildren(h("p", { class: "empty" }, "The contracts could not be read. Check the addresses and the RPC."));
  }
}

function paintChain() {
  state.cfg = chainConfig(state.chainId);
  fillSettings();
}

async function connectWallet() {
  if (!window.ethereum) {
    setStatus("No wallet found. Install a browser wallet and reload.", true);
    return;
  }
  state.browser = new ethers.BrowserProvider(window.ethereum);
  await state.browser.send("eth_requestAccounts", []);
  state.signer = await state.browser.getSigner();
  state.user = await state.signer.getAddress();
  state.walletChain = Number((await state.browser.getNetwork()).chainId);
  if (state.walletChain === 56 || state.walletChain === 97) {
    state.chainId = state.walletChain;
    localStorage.setItem("ajm.chain", String(state.chainId));
  }
  await refresh();
  if (state.walletChain !== state.chainId) {
    setStatus("Wallet is on chain " + state.walletChain + ". Switch to " + state.cfg.name + " to send transactions.", true);
  }
}

async function switchChain(chainId) {
  state.chainId = chainId;
  localStorage.setItem("ajm.chain", String(chainId));
  if (window.ethereum && state.user) {
    const cfg = chainConfig(chainId);
    try {
      await window.ethereum.request({ method: "wallet_switchEthereumChain", params: [{ chainId: cfg.hex }] });
    } catch (err) {
      if (err && err.code === 4902) {
        try {
          await window.ethereum.request({
            method: "wallet_addEthereumChain",
            params: [{
              chainId: cfg.hex,
              chainName: cfg.name,
              nativeCurrency: { name: "BNB", symbol: cfg.currency, decimals: 18 },
              rpcUrls: [cfg.rpc],
              blockExplorerUrls: [cfg.explorer],
            }],
          });
        } catch (addErr) {
          setStatus(explain(addErr), true);
        }
      } else if (err && err.code !== 4001) {
        setStatus(explain(err), true);
      }
    }
  }
  await refresh();
}

function saveSettings() {
  try {
    const next = {
      market: parseAddr($("set-market").value, "Market"),
      usdt: parseAddr($("set-usdt").value, "USDT"),
      registry: parseAddr($("set-registry").value, "Registry"),
    };
    localStorage.setItem("ajm.addresses." + state.chainId, JSON.stringify(next));
    setStatus("Saved addresses for " + chainConfig(state.chainId).name + " in this browser.");
    refresh();
  } catch (err) {
    setStatus(err.message, true);
  }
}

function parseAddr(value, label) {
  const trimmed = value.trim();
  if (!trimmed) return "";
  if (!ethers.isAddress(trimmed)) throw new Error(label + " is not an address.");
  return ethers.getAddress(trimmed);
}

function resetSettings() {
  localStorage.removeItem("ajm.addresses." + state.chainId);
  fillSettings();
  setStatus("Restored the default addresses.");
  refresh();
}

function bind() {
  $("connect").addEventListener("click", () => {
    connectWallet().catch((err) => setStatus(explain(err), true));
  });
  $("chain-97").addEventListener("click", () => switchChain(97));
  $("chain-56").addEventListener("click", () => switchChain(56));
  document.querySelectorAll(".tab").forEach((button) => {
    button.addEventListener("click", () => {
      state.tab = button.dataset.tab;
      document.querySelectorAll(".tab").forEach((tab) => {
        tab.setAttribute("aria-selected", tab === button ? "true" : "false");
      });
      render().catch((err) => setStatus(explain(err), true));
    });
  });
  $("save-settings").addEventListener("click", saveSettings);
  $("reset-settings").addEventListener("click", resetSettings);
  if (window.ethereum) {
    window.ethereum.on("chainChanged", () => window.location.reload());
    window.ethereum.on("accountsChanged", () => window.location.reload());
  }
}

async function boot() {
  if (!window.ethers || !window.AJM_CONFIG) {
    setStatus("The page scripts did not load.", true);
    return;
  }
  const stored = Number(localStorage.getItem("ajm.chain") || 97);
  state.chainId = stored === 56 ? 56 : 97;
  state.cfg = chainConfig(state.chainId);
  bind();
  if (window.ethereum) {
    try {
      const accounts = await window.ethereum.request({ method: "eth_accounts" });
      if (accounts && accounts.length) await connectWallet();
      else await refresh();
    } catch {
      await refresh();
    }
  } else {
    await refresh();
  }
}

boot().catch((err) => {
  console.error(err);
  setStatus(explain(err), true);
});
