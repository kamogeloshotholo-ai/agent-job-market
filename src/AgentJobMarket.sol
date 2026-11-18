// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAgentIdRegistry} from "./interfaces/IAgentIdRegistry.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {FeeMath} from "./libraries/FeeMath.sol";
import {SafeERC20} from "./libraries/SafeERC20.sol";
import {ReentrancyGuard} from "./utils/ReentrancyGuard.sol";

/// @title AgentJobMarket
/// @notice Pay-per-job escrow between Binance Agent IDs.
///
///         A poster with an Agent ID locks BEP-20 USDT. Another Agent ID accepts,
///         submits a result hash, and the poster approves the payout. If nobody
///         accepts, or the worker never submits, the bounty refunds. After a
///         result is in, silence pays the worker; a dispute is settled by both
///         parties agreeing a split, by one side conceding, or by a 50/50 timeout.
///
///         Receipts store both Agent ID handles, the spec hash, the result hash,
///         and the amounts paid. Names are snapshotted when each agent acts.
///         Payment always goes to the address that posted or accepted, never to a
///         fresh registry lookup, so a later registry change cannot redirect funds.
///
/// @dev No owner, no pause, no fee change, and no function that sweeps escrow.
///      The protocol fee is optional, immutable, and capped at {MAX_FEE_BPS}.
///      Direct token transfers to this contract are not escrow and are not
///      recoverable. That is deliberate: a rescue function would be an admin rug.
contract AgentJobMarket is ReentrancyGuard {
    enum Status {
        None,
        Open,
        Accepted,
        Submitted,
        Completed,
        Refunded,
        Disputed,
        Resolved
    }

    enum ReceiptKind {
        Payout,
        Refund,
        Split
    }

    struct PostRequest {
        uint256 bounty;
        string title;
        string tag;
        bytes32 specHash;
        string specUri;
        uint64 acceptWindow;
        uint64 submitWindow;
        uint64 reviewWindow;
    }

    struct Job {
        address poster;
        address worker;
        uint256 bounty;
        bytes32 specHash;
        bytes32 resultHash;
        bytes32 disputeReason;
        uint64 acceptBy;
        uint64 submitBy;
        uint64 reviewBy;
        uint64 disputeBy;
        uint64 submitWindow;
        uint64 reviewWindow;
        Status status;
        string posterName;
        string workerName;
        string title;
        string tag;
        string specUri;
        string resultUri;
    }

    struct Receipt {
        uint256 jobId;
        address poster;
        address worker;
        uint256 bounty;
        uint256 workerPayout;
        uint256 posterRefund;
        uint256 protocolFee;
        bytes32 specHash;
        bytes32 resultHash;
        bytes32 reason;
        uint64 settledAt;
        ReceiptKind kind;
        string posterName;
        string workerName;
        string title;
        string tag;
        string resultUri;
    }

    struct SplitProposal {
        uint256 bps;
        bool set;
    }

    uint256 public constant MAX_FEE_BPS = 500;
    uint256 public constant BPS = FeeMath.BPS;
    uint64 public constant MIN_WINDOW = 15 minutes;
    uint64 public constant MAX_WINDOW = 30 days;
    uint64 public constant DISPUTE_WINDOW = 3 days;
    uint256 public constant MAX_PAGE = 50;
    uint256 public constant MAX_TITLE_BYTES = 80;
    uint256 public constant MAX_TAG_BYTES = 24;
    uint256 public constant MAX_URI_BYTES = 256;
    /// @dev The live registry reports `maxLen() == 20`. The market allows up to 64
    ///      bytes so a longer future handle still fits, and rejects anything larger
    ///      so a hostile registry cannot force a huge string into storage.
    uint256 public constant MAX_HANDLE_BYTES = 64;

    bytes32 public constant REASON_APPROVE = "APPROVE";
    bytes32 public constant REASON_CLAIM = "CLAIM";
    bytes32 public constant REASON_RELEASE = "RELEASE";
    bytes32 public constant REASON_SPLIT = "SPLIT";
    bytes32 public constant REASON_DISPUTE_TIMEOUT = "DISPUTE_TIMEOUT";
    bytes32 public constant REASON_CANCEL = "CANCEL";
    bytes32 public constant REASON_ACCEPT_TIMEOUT = "ACCEPT_TIMEOUT";
    bytes32 public constant REASON_SUBMIT_TIMEOUT = "SUBMIT_TIMEOUT";
    bytes32 public constant REASON_CONCEDE = "CONCEDE";

    IERC20 public immutable usdt;
    IAgentIdRegistry public immutable registry;
    address public immutable feeRecipient;
    uint256 public immutable feeBps;
    uint256 public immutable minBounty;

    uint256 public jobCount;
    uint256 public receiptCount;
    /// @notice Sum of bounties still held for unsettled jobs. Donations are excluded.
    uint256 public escrowed;

    mapping(uint256 => Job) private jobs;
    mapping(uint256 => Receipt) private receipts;
    mapping(uint256 => uint256) public receiptOfJob;
    mapping(uint256 => SplitProposal) public posterSplit;
    mapping(uint256 => SplitProposal) public workerSplit;

    uint256[] private _openJobs;
    mapping(uint256 => uint256) private _openIndex;
    mapping(address => uint256[]) private _byPoster;
    mapping(address => uint256[]) private _byWorker;

    event MarketDeployed(
        address indexed usdt, address indexed registry, address indexed feeRecipient, uint256 feeBps, uint256 minBounty
    );
    event JobPosted(
        uint256 indexed jobId,
        address indexed poster,
        string posterName,
        string title,
        string tag,
        uint256 bounty,
        bytes32 specHash,
        string specUri,
        uint64 acceptBy
    );
    event JobAccepted(uint256 indexed jobId, address indexed worker, string workerName, uint64 submitBy);
    event ResultSubmitted(
        uint256 indexed jobId, address indexed worker, bytes32 resultHash, string resultUri, uint64 reviewBy
    );
    event JobDisputed(uint256 indexed jobId, address indexed poster, bytes32 reason, uint64 disputeBy);
    event SplitProposed(uint256 indexed jobId, address indexed proposer, uint256 workerBps);
    event JobSettled(
        uint256 indexed jobId,
        address indexed poster,
        address indexed worker,
        uint256 workerPayout,
        uint256 posterRefund,
        uint256 protocolFee,
        ReceiptKind kind,
        bytes32 reason
    );
    event ReceiptWritten(
        uint256 indexed receiptId,
        uint256 indexed jobId,
        string posterName,
        string workerName,
        bytes32 resultHash,
        uint256 workerPayout,
        bytes32 reason
    );

    error ZeroAddress();
    error NoCode();
    error FeeTooHigh(uint256 feeBps);
    error FeeRecipientRequired();
    error FeeRecipientInvalid();
    error NoValue();
    error UnknownJob(uint256 jobId);
    error UnknownReceipt(uint256 receiptId);
    error NoAgentId(address account);
    error HandleTooLong(address account);
    error AgentIdMismatch(address account, string handle);
    error BadTitle();
    error TagTooLong();
    error EmptySpec();
    error EmptyResult();
    error EmptyReason();
    error UriTooLong();
    error WindowOutOfRange(uint64 window);
    error BountyTooSmall(uint256 amount, uint256 minimum);
    error UnexpectedCredit(uint256 received, uint256 requested);
    error BadStatus(uint256 jobId, Status status);
    error NotPoster(uint256 jobId);
    error NotWorker(uint256 jobId);
    error NotParty(uint256 jobId);
    error SelfAccept(uint256 jobId);
    error AcceptWindowOver(uint256 jobId);
    error AcceptWindowOpen(uint256 jobId);
    error SubmitWindowOver(uint256 jobId);
    error SubmitWindowOpen(uint256 jobId);
    error ReviewWindowOpen(uint256 jobId);
    error ReviewWindowOver(uint256 jobId);
    error DisputeWindowOpen(uint256 jobId);
    error SplitOutOfRange(uint256 workerBps);
    error InvalidPayee(address to);
    error FeeOnTransferOut(address to, uint256 expected, uint256 actual);
    error Accounting(uint256 jobId);
    error PageTooLarge(uint256 size);

    /// @param usdt_ BEP-20 used as the bounty token. On BSC mainnet this is USDT.
    /// @param registry_ Agent ID registry. On BSC mainnet, the SPACE ID registry.
    /// @param feeRecipient_ Receives the protocol fee. Required when `feeBps_` is not zero.
    /// @param feeBps_ Fee on the worker's gross, in basis points. Immutable. Max {MAX_FEE_BPS}.
    /// @param minBounty_ Smallest escrow the market will accept, in token base units.
    constructor(address usdt_, address registry_, address feeRecipient_, uint256 feeBps_, uint256 minBounty_) payable {
        if (msg.value != 0) revert NoValue();
        if (usdt_ == address(0) || registry_ == address(0)) revert ZeroAddress();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh(feeBps_);
        if (feeBps_ > 0 && feeRecipient_ == address(0)) revert FeeRecipientRequired();
        if (feeRecipient_ == address(this)) revert FeeRecipientInvalid();
        if (usdt_.code.length == 0 || registry_.code.length == 0) revert NoCode();

        usdt = IERC20(usdt_);
        registry = IAgentIdRegistry(registry_);
        feeRecipient = feeRecipient_;
        feeBps = feeBps_;
        minBounty = minBounty_;
        emit MarketDeployed(usdt_, registry_, feeRecipient_, feeBps_, minBounty_);
    }

    receive() external payable {
        revert NoValue();
    }

    fallback() external payable {
        revert NoValue();
    }

    /// @notice Lock `req.bounty` of USDT and open a job. Caller must hold an Agent ID.
    ///         The stored bounty is the amount that actually arrived.
    function postJob(PostRequest calldata req) external nonReentrant returns (uint256 jobId) {
        uint256 titleLen = bytes(req.title).length;
        if (titleLen == 0 || titleLen > MAX_TITLE_BYTES) revert BadTitle();
        if (bytes(req.tag).length > MAX_TAG_BYTES) revert TagTooLong();
        if (req.specHash == bytes32(0)) revert EmptySpec();
        if (bytes(req.specUri).length > MAX_URI_BYTES) revert UriTooLong();
        _checkWindow(req.acceptWindow);
        _checkWindow(req.submitWindow);
        _checkWindow(req.reviewWindow);
        if (req.bounty == 0 || req.bounty < minBounty) revert BountyTooSmall(req.bounty, minBounty);

        string memory name = _agentName(msg.sender);
        uint256 received = _pull(msg.sender, req.bounty);

        jobId = ++jobCount;
        Job storage job = jobs[jobId];
        job.poster = msg.sender;
        job.bounty = received;
        job.specHash = req.specHash;
        job.acceptBy = uint64(block.timestamp) + req.acceptWindow;
        job.submitWindow = req.submitWindow;
        job.reviewWindow = req.reviewWindow;
        job.status = Status.Open;
        job.posterName = name;
        job.title = req.title;
        job.tag = req.tag;
        job.specUri = req.specUri;

        _addOpen(jobId);
        _byPoster[msg.sender].push(jobId);

        emit JobPosted(jobId, msg.sender, name, req.title, req.tag, received, req.specHash, req.specUri, job.acceptBy);
    }

    /// @notice Poster cancels an open job and takes the bounty back. No fee.
    function cancel(uint256 jobId) external nonReentrant {
        Job storage job = _existing(jobId);
        if (msg.sender != job.poster) revert NotPoster(jobId);
        if (job.status != Status.Open) revert BadStatus(jobId, job.status);
        _settle(job, jobId, Status.Refunded, 0, REASON_CANCEL);
    }

    /// @notice Another Agent ID takes an open job. The poster cannot accept their own.
    function accept(uint256 jobId) external nonReentrant {
        Job storage job = _existing(jobId);
        if (job.status != Status.Open) revert BadStatus(jobId, job.status);
        if (block.timestamp > job.acceptBy) revert AcceptWindowOver(jobId);
        if (msg.sender == job.poster) revert SelfAccept(jobId);

        string memory name = _agentName(msg.sender);
        job.worker = msg.sender;
        job.workerName = name;
        job.status = Status.Accepted;
        job.submitBy = uint64(block.timestamp) + job.submitWindow;
        _removeOpen(jobId);
        _byWorker[msg.sender].push(jobId);

        emit JobAccepted(jobId, msg.sender, name, job.submitBy);
    }

    /// @notice Worker commits a result. `resultHash` is typically `keccak256` of the
    ///         off-chain report. `resultUri` is an optional pointer, not the report.
    function submit(uint256 jobId, bytes32 resultHash, string calldata resultUri) external nonReentrant {
        Job storage job = _existing(jobId);
        if (job.status != Status.Accepted) revert BadStatus(jobId, job.status);
        if (msg.sender != job.worker) revert NotWorker(jobId);
        if (block.timestamp > job.submitBy) revert SubmitWindowOver(jobId);
        if (resultHash == bytes32(0)) revert EmptyResult();
        if (bytes(resultUri).length > MAX_URI_BYTES) revert UriTooLong();

        job.resultHash = resultHash;
        job.resultUri = resultUri;
        job.status = Status.Submitted;
        job.reviewBy = uint64(block.timestamp) + job.reviewWindow;

        emit ResultSubmitted(jobId, msg.sender, resultHash, resultUri, job.reviewBy);
    }

    /// @notice Poster pays the worker. Allowed any time after submission, until a
    ///         claim, dispute, or other terminal transition.
    function approve(uint256 jobId) external nonReentrant {
        Job storage job = _existing(jobId);
        if (job.status != Status.Submitted) revert BadStatus(jobId, job.status);
        if (msg.sender != job.poster) revert NotPoster(jobId);
        _settle(job, jobId, Status.Completed, BPS, REASON_APPROVE);
    }

    /// @notice Worker collects the payout after the review window with no poster action.
    ///         Silence is acceptance. Dispute before the window if the result is bad.
    function claim(uint256 jobId) external nonReentrant {
        Job storage job = _existing(jobId);
        if (job.status != Status.Submitted) revert BadStatus(jobId, job.status);
        if (msg.sender != job.worker) revert NotWorker(jobId);
        if (block.timestamp <= job.reviewBy) revert ReviewWindowOpen(jobId);
        _settle(job, jobId, Status.Completed, BPS, REASON_CLAIM);
    }

    /// @notice Anyone may refund a job that nobody accepted, or that was accepted
    ///         and never submitted, once that deadline has passed. Funds return to
    ///         the poster. No fee. Cancel is the path while the accept window is open.
    function refund(uint256 jobId) external nonReentrant {
        Job storage job = _existing(jobId);
        Status status = job.status;
        if (status == Status.Open) {
            if (block.timestamp <= job.acceptBy) revert AcceptWindowOpen(jobId);
            _settle(job, jobId, Status.Refunded, 0, REASON_ACCEPT_TIMEOUT);
            return;
        }
        if (status == Status.Accepted) {
            if (block.timestamp <= job.submitBy) revert SubmitWindowOpen(jobId);
            _settle(job, jobId, Status.Refunded, 0, REASON_SUBMIT_TIMEOUT);
            return;
        }
        revert BadStatus(jobId, status);
    }

    /// @notice Poster rejects a submitted result. Must be inside the review window.
    ///         `reason` is an opaque commitment (hash a sentence off-chain if you want).
    function dispute(uint256 jobId, bytes32 reason) external nonReentrant {
        Job storage job = _existing(jobId);
        if (job.status != Status.Submitted) revert BadStatus(jobId, job.status);
        if (msg.sender != job.poster) revert NotPoster(jobId);
        if (block.timestamp > job.reviewBy) revert ReviewWindowOver(jobId);
        if (reason == bytes32(0)) revert EmptyReason();

        job.status = Status.Disputed;
        job.disputeReason = reason;
        job.disputeBy = uint64(block.timestamp) + DISPUTE_WINDOW;
        emit JobDisputed(jobId, msg.sender, reason, job.disputeBy);
    }

    /// @notice Worker gives the bounty back to the poster.
    function concede(uint256 jobId) external nonReentrant {
        Job storage job = _existing(jobId);
        if (job.status != Status.Disputed) revert BadStatus(jobId, job.status);
        if (msg.sender != job.worker) revert NotWorker(jobId);
        _settle(job, jobId, Status.Resolved, 0, REASON_CONCEDE);
    }

    /// @notice Poster changes their mind and pays the worker in full.
    function release(uint256 jobId) external nonReentrant {
        Job storage job = _existing(jobId);
        if (job.status != Status.Disputed) revert BadStatus(jobId, job.status);
        if (msg.sender != job.poster) revert NotPoster(jobId);
        _settle(job, jobId, Status.Resolved, BPS, REASON_RELEASE);
    }

    /// @notice Either party proposes the worker's share of the bounty, in basis points.
    ///         When both proposals match, the job settles in that transaction.
    ///         A later proposal from the same side replaces the earlier one.
    function proposeSplit(uint256 jobId, uint256 workerBps) external nonReentrant {
        if (workerBps > BPS) revert SplitOutOfRange(workerBps);
        Job storage job = _existing(jobId);
        if (job.status != Status.Disputed) revert BadStatus(jobId, job.status);

        if (msg.sender == job.poster) {
            posterSplit[jobId] = SplitProposal(workerBps, true);
        } else if (msg.sender == job.worker) {
            workerSplit[jobId] = SplitProposal(workerBps, true);
        } else {
            revert NotParty(jobId);
        }
        emit SplitProposed(jobId, msg.sender, workerBps);

        SplitProposal memory posterProposal = posterSplit[jobId];
        SplitProposal memory workerProposal = workerSplit[jobId];
        if (posterProposal.set && workerProposal.set && posterProposal.bps == workerProposal.bps) {
            _settle(job, jobId, Status.Resolved, workerBps, REASON_SPLIT);
        }
    }

    /// @notice Anyone may settle an unresolved dispute after {DISPUTE_WINDOW}.
    ///         The worker's gross is half the bounty. The fee applies to that half.
    function resolveDisputeTimeout(uint256 jobId) external nonReentrant {
        Job storage job = _existing(jobId);
        if (job.status != Status.Disputed) revert BadStatus(jobId, job.status);
        if (block.timestamp <= job.disputeBy) revert DisputeWindowOpen(jobId);
        _settle(job, jobId, Status.Resolved, 5000, REASON_DISPUTE_TIMEOUT);
    }

    /// @notice Preview a settlement. `workerBps` is the worker's gross share.
    ///         Full approval is `workerBps == BPS`. A full refund is `0`.
    function quote(uint256 bounty, uint256 workerBps)
        external
        view
        returns (uint256 workerNet, uint256 posterRefund, uint256 fee)
    {
        if (workerBps > BPS) revert SplitOutOfRange(workerBps);
        return FeeMath.quote(bounty, workerBps, feeBps);
    }

    /// @notice Non-reverting Agent ID check used by the app. `ok` requires a
    ///         non-empty handle that resolves back to `account`.
    function resolveAgent(address account) external view returns (bool ok, string memory name) {
        name = registry.handleOf(account);
        uint256 len = bytes(name).length;
        if (len == 0 || len > MAX_HANDLE_BYTES) return (false, "");
        if (registry.ownerOfHandle(name) != account) return (false, "");
        ok = true;
    }

    function getJob(uint256 jobId) external view returns (Job memory) {
        return _existingMemory(jobId);
    }

    function getJobs(uint256[] calldata ids) external view returns (Job[] memory out) {
        uint256 n = ids.length;
        if (n > MAX_PAGE) revert PageTooLarge(n);
        out = new Job[](n);
        for (uint256 i = 0; i < n; ++i) {
            out[i] = _existingMemory(ids[i]);
        }
    }

    function getReceipt(uint256 receiptId) external view returns (Receipt memory) {
        if (receiptId == 0 || receiptId > receiptCount) revert UnknownReceipt(receiptId);
        return receipts[receiptId];
    }

    /// @notice Receipts are 1-based. `startId` through `startId + count - 1`, clipped
    ///         to the last receipt. `count` is clipped to {MAX_PAGE}.
    function getReceipts(uint256 startId, uint256 count) external view returns (Receipt[] memory out) {
        if (count > MAX_PAGE) count = MAX_PAGE;
        if (startId == 0 || startId > receiptCount || count == 0) return new Receipt[](0);
        uint256 end = startId + count - 1;
        if (end > receiptCount) end = receiptCount;
        out = new Receipt[](end - startId + 1);
        for (uint256 i = startId; i <= end; ++i) {
            out[i - startId] = receipts[i];
        }
    }

    function openJobCount() external view returns (uint256) {
        return _openJobs.length;
    }

    function openJobIds(uint256 offset, uint256 limit) external view returns (uint256[] memory) {
        return _page(_openJobs, offset, limit);
    }

    function posterJobCount(address account) external view returns (uint256) {
        return _byPoster[account].length;
    }

    function posterJobIds(address account, uint256 offset, uint256 limit) external view returns (uint256[] memory) {
        return _page(_byPoster[account], offset, limit);
    }

    function workerJobCount(address account) external view returns (uint256) {
        return _byWorker[account].length;
    }

    function workerJobIds(address account, uint256 offset, uint256 limit) external view returns (uint256[] memory) {
        return _page(_byWorker[account], offset, limit);
    }

    function _settle(Job storage job, uint256 jobId, Status next, uint256 workerBps, bytes32 reason) internal {
        (uint256 workerNet, uint256 posterRefund, uint256 fee) = FeeMath.quote(job.bounty, workerBps, feeBps);
        if (workerNet + posterRefund + fee != job.bounty) revert Accounting(jobId);

        _removeOpen(jobId);
        job.status = next;
        ReceiptKind kind = _kindFor(workerBps);
        _writeReceipt(job, jobId, kind, workerNet, posterRefund, fee, reason);
        emit JobSettled(jobId, job.poster, job.worker, workerNet, posterRefund, fee, kind, reason);

        escrowed -= job.bounty;
        _pay(job.worker, workerNet);
        _pay(job.poster, posterRefund);
        _pay(feeRecipient, fee);
    }

    function _writeReceipt(
        Job storage job,
        uint256 jobId,
        ReceiptKind kind,
        uint256 workerPayout,
        uint256 posterRefund,
        uint256 protocolFee,
        bytes32 reason
    ) internal {
        uint256 receiptId = ++receiptCount;
        Receipt storage receipt = receipts[receiptId];
        receipt.jobId = jobId;
        receipt.poster = job.poster;
        receipt.worker = job.worker;
        receipt.bounty = job.bounty;
        receipt.workerPayout = workerPayout;
        receipt.posterRefund = posterRefund;
        receipt.protocolFee = protocolFee;
        receipt.specHash = job.specHash;
        receipt.resultHash = job.resultHash;
        receipt.reason = reason;
        receipt.settledAt = uint64(block.timestamp);
        receipt.kind = kind;
        receipt.posterName = job.posterName;
        receipt.workerName = job.workerName;
        receipt.title = job.title;
        receipt.tag = job.tag;
        receipt.resultUri = job.resultUri;
        receiptOfJob[jobId] = receiptId;

        emit ReceiptWritten(receiptId, jobId, job.posterName, job.workerName, job.resultHash, workerPayout, reason);
    }

    function _pull(address from, uint256 amount) internal returns (uint256 received) {
        uint256 beforeBal = usdt.balanceOf(address(this));
        SafeERC20.safeTransferFrom(usdt, from, address(this), amount);
        received = usdt.balanceOf(address(this)) - beforeBal;
        if (received == 0 || received < minBounty) revert BountyTooSmall(received, minBounty);
        if (received > amount) revert UnexpectedCredit(received, amount);
        escrowed += received;
    }

    /// @dev Requires the recipient's balance to rise by exactly `amount`.
    ///      Standard USDT does this. A fee-on-transfer token would record a lie, so
    ///      the settlement reverts and the job stays as it was.
    function _pay(address to, uint256 amount) internal {
        if (amount == 0) return;
        if (to == address(0) || to == address(this)) revert InvalidPayee(to);
        uint256 beforeTo = usdt.balanceOf(to);
        SafeERC20.safeTransfer(usdt, to, amount);
        uint256 credited = usdt.balanceOf(to) - beforeTo;
        if (credited != amount) revert FeeOnTransferOut(to, amount, credited);
    }

    function _agentName(address account) internal view returns (string memory name) {
        name = registry.handleOf(account);
        uint256 len = bytes(name).length;
        if (len == 0) revert NoAgentId(account);
        if (len > MAX_HANDLE_BYTES) revert HandleTooLong(account);
        if (registry.ownerOfHandle(name) != account) revert AgentIdMismatch(account, name);
    }

    function _existing(uint256 jobId) internal view returns (Job storage job) {
        job = jobs[jobId];
        if (job.poster == address(0)) revert UnknownJob(jobId);
    }

    function _existingMemory(uint256 jobId) internal view returns (Job memory job) {
        job = jobs[jobId];
        if (job.poster == address(0)) revert UnknownJob(jobId);
    }

    function _checkWindow(uint64 window) internal pure {
        if (window < MIN_WINDOW || window > MAX_WINDOW) revert WindowOutOfRange(window);
    }

    function _kindFor(uint256 workerBps) internal pure returns (ReceiptKind) {
        if (workerBps == 0) return ReceiptKind.Refund;
        if (workerBps == BPS) return ReceiptKind.Payout;
        return ReceiptKind.Split;
    }

    function _addOpen(uint256 jobId) internal {
        _openJobs.push(jobId);
        _openIndex[jobId] = _openJobs.length;
    }

    function _removeOpen(uint256 jobId) internal {
        uint256 index = _openIndex[jobId];
        if (index == 0) return;
        uint256 last = _openJobs.length;
        if (index != last) {
            uint256 moved = _openJobs[last - 1];
            _openJobs[index - 1] = moved;
            _openIndex[moved] = index;
        }
        _openJobs.pop();
        delete _openIndex[jobId];
    }

    function _page(uint256[] storage ids, uint256 offset, uint256 limit) internal view returns (uint256[] memory out) {
        if (limit > MAX_PAGE) limit = MAX_PAGE;
        uint256 n = ids.length;
        if (offset >= n || limit == 0) return new uint256[](0);
        uint256 end = offset + limit;
        if (end > n) end = n;
        out = new uint256[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            out[i - offset] = ids[i];
        }
    }
}
