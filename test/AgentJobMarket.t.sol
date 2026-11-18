// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AgentJobMarket} from "../src/AgentJobMarket.sol";
import {IAgentIdRegistry} from "../src/interfaces/IAgentIdRegistry.sol";
import {MockAgentIdRegistry} from "../src/mocks/MockAgentIdRegistry.sol";
import {MockUSDT} from "../src/mocks/MockUSDT.sol";
import {ReentrancyGuard} from "../src/utils/ReentrancyGuard.sol";
import {MockERC20, NoReturnToken, ReentrantToken, ScriptedRegistry, ShortingToken} from "./mocks/Tokens.sol";

contract AgentJobMarketTest is Test {
    uint256 internal constant FEE_BPS = 500;
    uint256 internal constant BOUNTY = 100 ether;
    uint64 internal constant WINDOW = 1 hours;

    MockAgentIdRegistry internal registry;
    MockERC20 internal usdt;
    AgentJobMarket internal market;

    address internal poster = makeAddr("poster");
    address internal worker = makeAddr("worker");
    address internal other = makeAddr("other");
    address internal feeTo = makeAddr("fee");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        registry = new MockAgentIdRegistry();
        usdt = new MockERC20("Mock USDT", "USDT");
        market = new AgentJobMarket(address(usdt), address(registry), feeTo, FEE_BPS, 1 ether);

        _register(poster, "poster");
        _register(worker, "worker");
        _register(other, "other");

        usdt.mint(poster, 1_000_000 ether);
        vm.prank(poster);
        usdt.approve(address(market), type(uint256).max);
    }

    function test_agentIdSelectorsMatchMainnet() public pure {
        assertEq(IAgentIdRegistry.handleOf.selector, bytes4(hex"c50a1514"));
        assertEq(IAgentIdRegistry.ownerOfHandle.selector, bytes4(hex"1da94fb4"));
    }

    function test_happyPath_receiptNamesFeeAndEvents() public {
        uint256 id = _post();
        uint256 posterBefore = usdt.balanceOf(poster);

        vm.prank(worker);
        market.accept(id);

        bytes32 result = keccak256("audit report");
        vm.prank(worker);
        market.submit(id, result, "ipfs://report");

        (uint256 workerNet, uint256 posterRefund, uint256 fee) = market.quote(BOUNTY, market.BPS());
        assertEq(workerNet, 95 ether);
        assertEq(posterRefund, 0);
        assertEq(fee, 5 ether);

        vm.expectEmit(true, true, false, true, address(market));
        emit AgentJobMarket.ReceiptWritten(1, id, "poster", "worker", result, workerNet, market.REASON_APPROVE());
        vm.expectEmit(true, true, true, true, address(market));
        emit AgentJobMarket.JobSettled(
            id, poster, worker, workerNet, 0, fee, AgentJobMarket.ReceiptKind.Payout, market.REASON_APPROVE()
        );
        vm.prank(poster);
        market.approve(id);

        AgentJobMarket.Job memory job = market.getJob(id);
        assertEq(uint256(job.status), uint256(AgentJobMarket.Status.Completed));
        assertEq(job.posterName, "poster");
        assertEq(job.workerName, "worker");
        assertEq(job.resultHash, result);
        assertEq(job.title, "Token safety audit");
        assertEq(registry.ownerOfHandle(job.posterName), poster);
        assertEq(registry.ownerOfHandle(job.workerName), worker);

        AgentJobMarket.Receipt memory receipt = market.getReceipt(market.receiptOfJob(id));
        assertEq(receipt.posterName, "poster");
        assertEq(receipt.workerName, "worker");
        assertEq(receipt.resultHash, result);
        assertEq(receipt.workerPayout, 95 ether);
        assertEq(receipt.posterRefund, 0);
        assertEq(receipt.protocolFee, 5 ether);
        assertEq(receipt.bounty, BOUNTY);
        assertEq(receipt.specHash, job.specHash);
        assertEq(uint256(receipt.kind), uint256(AgentJobMarket.ReceiptKind.Payout));
        assertEq(receipt.reason, market.REASON_APPROVE());

        assertEq(usdt.balanceOf(worker), 95 ether);
        assertEq(usdt.balanceOf(feeTo), 5 ether);
        assertEq(usdt.balanceOf(poster), posterBefore);
        assertEq(usdt.balanceOf(address(market)), 0);
        assertEq(market.escrowed(), 0);
        assertEq(market.openJobCount(), 0);
    }

    function test_cancel_refundsFullWithoutFee() public {
        uint256 id = _post();
        uint256 before = usdt.balanceOf(poster);
        vm.prank(poster);
        market.cancel(id);

        AgentJobMarket.Receipt memory receipt = market.getReceipt(1);
        assertEq(uint256(receipt.kind), uint256(AgentJobMarket.ReceiptKind.Refund));
        assertEq(receipt.reason, market.REASON_CANCEL());
        assertEq(receipt.workerPayout, 0);
        assertEq(receipt.posterRefund, BOUNTY);
        assertEq(receipt.protocolFee, 0);
        assertEq(receipt.workerName, "");
        assertEq(receipt.posterName, "poster");
        assertEq(usdt.balanceOf(poster), before + BOUNTY);
        assertEq(usdt.balanceOf(feeTo), 0);
        assertEq(market.escrowed(), 0);
        assertEq(uint256(market.getJob(id).status), uint256(AgentJobMarket.Status.Refunded));
    }

    function test_refund_acceptTimeout_anyoneCanCall() public {
        uint256 id = _post();
        AgentJobMarket.Job memory job = market.getJob(id);
        vm.warp(job.acceptBy + 1);
        uint256 before = usdt.balanceOf(poster);

        vm.prank(stranger);
        market.refund(id);

        AgentJobMarket.Receipt memory receipt = market.getReceipt(1);
        assertEq(receipt.reason, market.REASON_ACCEPT_TIMEOUT());
        assertEq(receipt.posterRefund, BOUNTY);
        assertEq(usdt.balanceOf(poster), before + BOUNTY);
        assertEq(market.escrowed(), 0);
    }

    function test_refund_submitTimeout() public {
        uint256 id = _accept();
        vm.warp(market.getJob(id).submitBy + 1);
        uint256 before = usdt.balanceOf(poster);

        market.refund(id);

        assertEq(market.getReceipt(1).reason, market.REASON_SUBMIT_TIMEOUT());
        assertEq(usdt.balanceOf(poster), before + BOUNTY);
        assertEq(usdt.balanceOf(worker), 0);
        assertEq(market.escrowed(), 0);
    }

    function test_refund_beforeAcceptTimeout_reverts() public {
        uint256 id = _post();
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.AcceptWindowOpen.selector, id));
        market.refund(id);
    }

    function test_refund_beforeSubmitTimeout_reverts() public {
        uint256 id = _accept();
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.SubmitWindowOpen.selector, id));
        market.refund(id);
    }

    function test_cancel_afterAccept_reverts() public {
        uint256 id = _accept();
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.BadStatus.selector, id, AgentJobMarket.Status.Accepted));
        market.cancel(id);
    }

    function test_workerCannotCancel() public {
        uint256 id = _post();
        vm.prank(worker);
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.NotPoster.selector, id));
        market.cancel(id);
    }

    function test_nonAgent_cannotPost() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.NoAgentId.selector, stranger));
        market.postJob(_request(BOUNTY));
    }

    function test_nonAgent_cannotAccept() public {
        uint256 id = _post();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.NoAgentId.selector, stranger));
        market.accept(id);
    }

    function test_agentMismatch_reverts() public {
        ScriptedRegistry scripted = new ScriptedRegistry();
        AgentJobMarket gated = new AgentJobMarket(address(usdt), address(scripted), feeTo, FEE_BPS, 1 ether);
        scripted.set(poster, "poster", other);
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.AgentIdMismatch.selector, poster, "poster"));
        gated.postJob(_request(BOUNTY));
    }

    function test_handleTooLong_reverts() public {
        ScriptedRegistry scripted = new ScriptedRegistry();
        AgentJobMarket gated = new AgentJobMarket(address(usdt), address(scripted), feeTo, FEE_BPS, 1 ether);
        string memory huge = _repeat("a", 65);
        scripted.set(poster, huge, poster);
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.HandleTooLong.selector, poster));
        gated.postJob(_request(BOUNTY));
    }

    function test_resolveAgent_falseWhenMissingOrMismatched() public {
        (bool ok, string memory name) = market.resolveAgent(stranger);
        assertFalse(ok);
        assertEq(name, "");

        ScriptedRegistry scripted = new ScriptedRegistry();
        AgentJobMarket gated = new AgentJobMarket(address(usdt), address(scripted), address(0), 0, 0);
        scripted.set(poster, "poster", other);
        (ok, name) = gated.resolveAgent(poster);
        assertFalse(ok);
        assertEq(name, "");

        (ok, name) = market.resolveAgent(poster);
        assertTrue(ok);
        assertEq(name, "poster");
    }

    function test_selfAccept_reverts() public {
        uint256 id = _post();
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.SelfAccept.selector, id));
        market.accept(id);
    }

    function test_doubleAccept_reverts() public {
        uint256 id = _post();
        vm.prank(worker);
        market.accept(id);
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.BadStatus.selector, id, AgentJobMarket.Status.Accepted));
        market.accept(id);
    }

    function test_submitTwice_reverts() public {
        uint256 id = _submit();
        vm.prank(worker);
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.BadStatus.selector, id, AgentJobMarket.Status.Submitted));
        market.submit(id, keccak256("again"), "");
    }

    function test_approveTwice_reverts() public {
        uint256 id = _submit();
        vm.prank(poster);
        market.approve(id);
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.BadStatus.selector, id, AgentJobMarket.Status.Completed));
        market.approve(id);
    }

    function test_refundTwice_reverts() public {
        uint256 id = _post();
        vm.warp(market.getJob(id).acceptBy + 1);
        market.refund(id);
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.BadStatus.selector, id, AgentJobMarket.Status.Refunded));
        market.refund(id);
    }

    function test_workerCannotApprove_posterCannotSubmit() public {
        uint256 id = _accept();
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.NotWorker.selector, id));
        market.submit(id, keccak256("x"), "");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.NotWorker.selector, id));
        market.submit(id, keccak256("y"), "");

        _submitOn(id);
        vm.prank(worker);
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.NotPoster.selector, id));
        market.approve(id);
    }

    function test_acceptAfterDeadline_reverts_thenRefundWorks() public {
        uint256 id = _post();
        uint64 deadline = market.getJob(id).acceptBy;
        vm.warp(deadline);
        vm.prank(worker);
        market.accept(id);
        // A second job proves the boundary one second later.
        uint256 late = _post();
        vm.warp(market.getJob(late).acceptBy + 1);
        vm.prank(worker);
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.AcceptWindowOver.selector, late));
        market.accept(late);
        market.refund(late);
        assertEq(uint256(market.getJob(late).status), uint256(AgentJobMarket.Status.Refunded));
    }

    function test_submitAtDeadline_ok_afterDeadline_reverts() public {
        uint256 id = _accept();
        vm.warp(market.getJob(id).submitBy);
        vm.prank(worker);
        market.submit(id, keccak256("on-time"), "");

        uint256 late = _accept();
        vm.warp(market.getJob(late).submitBy + 1);
        vm.prank(worker);
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.SubmitWindowOver.selector, late));
        market.submit(late, keccak256("late"), "");
    }

    function test_claimBeforeReviewEnd_reverts() public {
        uint256 id = _submit();
        vm.prank(worker);
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.ReviewWindowOpen.selector, id));
        market.claim(id);
    }

    function test_claimAfterReviewEnd_paysWorker() public {
        uint256 id = _submit();
        vm.warp(market.getJob(id).reviewBy + 1);
        vm.prank(worker);
        market.claim(id);

        AgentJobMarket.Receipt memory receipt = market.getReceipt(1);
        assertEq(receipt.reason, market.REASON_CLAIM());
        assertEq(receipt.workerPayout, 95 ether);
        assertEq(usdt.balanceOf(worker), 95 ether);
        assertEq(usdt.balanceOf(feeTo), 5 ether);
        assertEq(market.escrowed(), 0);
    }

    function test_approveAfterReviewEnd_beatsClaim() public {
        uint256 id = _submit();
        vm.warp(market.getJob(id).reviewBy + 1);
        vm.prank(poster);
        market.approve(id);
        vm.prank(worker);
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.BadStatus.selector, id, AgentJobMarket.Status.Completed));
        market.claim(id);
        assertEq(market.getReceipt(1).reason, market.REASON_APPROVE());
    }

    function test_dispute_thenClaim_reverts() public {
        uint256 id = _submit();
        vm.prank(poster);
        market.dispute(id, keccak256("incomplete"));
        vm.warp(market.getJob(id).reviewBy + 1);
        vm.prank(worker);
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.BadStatus.selector, id, AgentJobMarket.Status.Disputed));
        market.claim(id);
    }

    function test_dispute_afterReviewWindow_reverts() public {
        uint256 id = _submit();
        vm.warp(market.getJob(id).reviewBy + 1);
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.ReviewWindowOver.selector, id));
        market.dispute(id, keccak256("late"));
    }

    function test_dispute_zeroReason_reverts() public {
        uint256 id = _submit();
        vm.prank(poster);
        vm.expectRevert(AgentJobMarket.EmptyReason.selector);
        market.dispute(id, bytes32(0));
    }

    function test_dispute_workerCannotDispute_posterCannotConcede() public {
        uint256 id = _submit();
        vm.prank(worker);
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.NotPoster.selector, id));
        market.dispute(id, keccak256("no"));

        vm.prank(poster);
        market.dispute(id, keccak256("bad result"));
        assertEq(market.getJob(id).disputeReason, keccak256("bad result"));

        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.NotWorker.selector, id));
        market.concede(id);
        vm.prank(worker);
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.NotPoster.selector, id));
        market.release(id);
    }

    function test_concede_refundsPoster() public {
        uint256 id = _dispute();
        uint256 before = usdt.balanceOf(poster);
        vm.prank(worker);
        market.concede(id);

        AgentJobMarket.Receipt memory receipt = market.getReceipt(1);
        assertEq(receipt.reason, market.REASON_CONCEDE());
        assertEq(uint256(receipt.kind), uint256(AgentJobMarket.ReceiptKind.Refund));
        assertEq(receipt.posterRefund, BOUNTY);
        assertEq(receipt.protocolFee, 0);
        assertEq(receipt.workerName, "worker");
        assertEq(usdt.balanceOf(poster), before + BOUNTY);
        assertEq(usdt.balanceOf(feeTo), 0);
        assertEq(uint256(market.getJob(id).status), uint256(AgentJobMarket.Status.Resolved));
    }

    function test_release_paysWorker() public {
        uint256 id = _dispute();
        vm.prank(poster);
        market.release(id);
        AgentJobMarket.Receipt memory receipt = market.getReceipt(1);
        assertEq(receipt.reason, market.REASON_RELEASE());
        assertEq(uint256(receipt.kind), uint256(AgentJobMarket.ReceiptKind.Payout));
        assertEq(receipt.workerPayout, 95 ether);
        assertEq(usdt.balanceOf(worker), 95 ether);
        assertEq(usdt.balanceOf(feeTo), 5 ether);
    }

    function test_splitHandshake_settlesOnMatch() public {
        uint256 id = _dispute();
        vm.prank(poster);
        market.proposeSplit(id, 2500);
        assertEq(uint256(market.getJob(id).status), uint256(AgentJobMarket.Status.Disputed));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.NotParty.selector, id));
        market.proposeSplit(id, 2500);

        vm.prank(worker);
        market.proposeSplit(id, 1000);
        assertEq(uint256(market.getJob(id).status), uint256(AgentJobMarket.Status.Disputed));

        vm.prank(worker);
        market.proposeSplit(id, 2500);

        (uint256 net, uint256 back, uint256 fee) = market.quote(BOUNTY, 2500);
        assertEq(net, 23.75 ether);
        assertEq(back, 75 ether);
        assertEq(fee, 1.25 ether);

        AgentJobMarket.Receipt memory receipt = market.getReceipt(1);
        assertEq(receipt.reason, market.REASON_SPLIT());
        assertEq(uint256(receipt.kind), uint256(AgentJobMarket.ReceiptKind.Split));
        assertEq(receipt.workerPayout, net);
        assertEq(receipt.posterRefund, back);
        assertEq(receipt.protocolFee, fee);
        assertEq(usdt.balanceOf(worker), net);
        assertEq(usdt.balanceOf(feeTo), fee);
        assertEq(net + back + fee, BOUNTY);
        assertEq(market.escrowed(), 0);

        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.BadStatus.selector, id, AgentJobMarket.Status.Resolved));
        market.proposeSplit(id, 2500);
    }

    function test_split_zeroAndFull() public {
        uint256 zeroId = _dispute();
        vm.prank(poster);
        market.proposeSplit(zeroId, 0);
        vm.prank(worker);
        market.proposeSplit(zeroId, 0);
        AgentJobMarket.Receipt memory refunded = market.getReceipt(market.receiptOfJob(zeroId));
        assertEq(uint256(refunded.kind), uint256(AgentJobMarket.ReceiptKind.Refund));
        assertEq(refunded.posterRefund, BOUNTY);
        assertEq(refunded.protocolFee, 0);

        uint256 fullId = _dispute();
        uint256 fullShare = market.BPS();
        vm.prank(worker);
        market.proposeSplit(fullId, fullShare);
        vm.prank(poster);
        market.proposeSplit(fullId, fullShare);
        AgentJobMarket.Receipt memory paid = market.getReceipt(market.receiptOfJob(fullId));
        assertEq(uint256(paid.kind), uint256(AgentJobMarket.ReceiptKind.Payout));
        assertEq(paid.workerPayout, 95 ether);
        assertEq(paid.protocolFee, 5 ether);
    }

    function test_splitOutOfRange_reverts() public {
        uint256 id = _dispute();
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.SplitOutOfRange.selector, 10_001));
        market.proposeSplit(id, 10_001);
    }

    function test_disputeTimeout_splitsHalf() public {
        uint256 id = _dispute();
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.DisputeWindowOpen.selector, id));
        market.resolveDisputeTimeout(id);

        vm.warp(market.getJob(id).disputeBy + 1);
        vm.prank(stranger);
        market.resolveDisputeTimeout(id);

        (uint256 net, uint256 back, uint256 fee) = market.quote(BOUNTY, 5000);
        assertEq(net, 47.5 ether);
        assertEq(back, 50 ether);
        assertEq(fee, 2.5 ether);
        AgentJobMarket.Receipt memory receipt = market.getReceipt(1);
        assertEq(receipt.reason, market.REASON_DISPUTE_TIMEOUT());
        assertEq(uint256(receipt.kind), uint256(AgentJobMarket.ReceiptKind.Split));
        assertEq(receipt.workerPayout, net);
        assertEq(receipt.posterRefund, back);
        assertEq(receipt.protocolFee, fee);
        assertEq(net + back + fee, BOUNTY);
        assertEq(usdt.balanceOf(worker), net);
        assertEq(usdt.balanceOf(feeTo), fee);
    }

    function test_twoJobs_escrowIsolated_andSwapPop() public {
        uint256 a = _post();
        uint256 b = _post();
        uint256 c = _post();
        assertEq(market.escrowed(), BOUNTY * 3);
        assertEq(market.openJobCount(), 3);

        vm.prank(worker);
        market.accept(b);
        assertEq(market.openJobCount(), 2);
        uint256[] memory open = market.openJobIds(0, 10);
        assertEq(open.length, 2);
        assertTrue((open[0] == a && open[1] == c) || (open[0] == c && open[1] == a));

        vm.prank(poster);
        market.cancel(a);
        assertEq(market.escrowed(), BOUNTY * 2);

        _submitOn(b);
        vm.prank(poster);
        market.approve(b);
        assertEq(market.escrowed(), BOUNTY);
        assertEq(market.openJobCount(), 1);

        vm.warp(market.getJob(c).acceptBy + 1);
        market.refund(c);
        assertEq(market.escrowed(), 0);
        assertEq(usdt.balanceOf(address(market)), 0);
        assertEq(market.receiptCount(), 3);
    }

    function test_workerCanTakeTwoJobs() public {
        uint256 a = _post();
        uint256 b = _post();
        vm.startPrank(worker);
        market.accept(a);
        market.accept(b);
        vm.stopPrank();
        assertEq(market.workerJobCount(worker), 2);
        assertEq(market.posterJobCount(poster), 2);
    }

    function test_quote_roundsFeeDown() public {
        AgentJobMarket tiny = new AgentJobMarket(address(usdt), address(registry), feeTo, FEE_BPS, 0);
        (uint256 net, uint256 back, uint256 fee) = tiny.quote(1, tiny.BPS());
        assertEq(fee, 0);
        assertEq(net, 1);
        assertEq(back, 0);

        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.SplitOutOfRange.selector, 10_001));
        tiny.quote(1, 10_001);
    }

    function test_feeAtCap_ok_aboveCap_reverts() public {
        AgentJobMarket capped = new AgentJobMarket(address(usdt), address(registry), feeTo, 500, 0);
        assertEq(capped.feeBps(), 500);
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.FeeTooHigh.selector, 501));
        new AgentJobMarket(address(usdt), address(registry), feeTo, 501, 0);
    }

    function test_feeZero_allowsZeroRecipient_andPaysNoFee() public {
        AgentJobMarket free = new AgentJobMarket(address(usdt), address(registry), address(0), 0, 1 ether);
        vm.prank(poster);
        usdt.approve(address(free), type(uint256).max);
        vm.prank(poster);
        uint256 id = free.postJob(_request(BOUNTY));
        vm.prank(worker);
        free.accept(id);
        vm.prank(worker);
        free.submit(id, keccak256("done"), "");
        vm.prank(poster);
        free.approve(id);
        assertEq(usdt.balanceOf(worker), BOUNTY);
        assertEq(free.getReceipt(1).protocolFee, 0);
        assertEq(usdt.balanceOf(address(free)), 0);
    }

    function test_feeWithoutRecipient_reverts() public {
        vm.expectRevert(AgentJobMarket.FeeRecipientRequired.selector);
        new AgentJobMarket(address(usdt), address(registry), address(0), 1, 0);
    }

    function test_constructor_rejectsZeroAndCodeless() public {
        vm.expectRevert(AgentJobMarket.ZeroAddress.selector);
        new AgentJobMarket(address(0), address(registry), feeTo, 0, 0);
        vm.expectRevert(AgentJobMarket.ZeroAddress.selector);
        new AgentJobMarket(address(usdt), address(0), feeTo, 0, 0);
        vm.expectRevert(AgentJobMarket.NoCode.selector);
        new AgentJobMarket(address(usdt), address(0xdead), feeTo, 0, 0);
    }

    function test_marketCanBeConstructedOnMainnetChain() public {
        vm.chainId(56);
        address token = address(0x1000);
        address reg = address(0x2000);
        vm.etch(token, hex"00");
        vm.etch(reg, hex"00");
        AgentJobMarket live = new AgentJobMarket(token, reg, address(0), 0, 0);
        assertEq(address(live.usdt()), token);
        assertEq(address(live.registry()), reg);
    }

    function test_rejectsBnb() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(AgentJobMarket.NoValue.selector);
        this.forwardValue{value: 1}(payable(address(market)));
    }

    function forwardValue(address payable to) external payable {
        (bool ok, bytes memory data) = to.call{value: msg.value}("");
        if (!ok) {
            assembly {
                revert(add(data, 32), mload(data))
            }
        }
    }

    function test_bountyBelowMin_andEmptyFields() public {
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.BountyTooSmall.selector, 1 ether - 1, 1 ether));
        market.postJob(_request(1 ether - 1));

        AgentJobMarket.PostRequest memory req = _request(BOUNTY);
        req.specHash = bytes32(0);
        vm.prank(poster);
        vm.expectRevert(AgentJobMarket.EmptySpec.selector);
        market.postJob(req);

        req = _request(BOUNTY);
        req.title = "";
        vm.prank(poster);
        vm.expectRevert(AgentJobMarket.BadTitle.selector);
        market.postJob(req);

        req = _request(BOUNTY);
        req.title = _repeat("t", 81);
        vm.prank(poster);
        vm.expectRevert(AgentJobMarket.BadTitle.selector);
        market.postJob(req);

        req = _request(BOUNTY);
        req.tag = _repeat("t", 25);
        vm.prank(poster);
        vm.expectRevert(AgentJobMarket.TagTooLong.selector);
        market.postJob(req);

        req = _request(BOUNTY);
        req.specUri = _repeat("u", 257);
        vm.prank(poster);
        vm.expectRevert(AgentJobMarket.UriTooLong.selector);
        market.postJob(req);

        uint256 id = _accept();
        vm.prank(worker);
        vm.expectRevert(AgentJobMarket.EmptyResult.selector);
        market.submit(id, bytes32(0), "");

        vm.prank(worker);
        vm.expectRevert(AgentJobMarket.UriTooLong.selector);
        market.submit(id, keccak256("ok"), _repeat("u", 257));
    }

    function test_windows_outOfRange() public {
        AgentJobMarket.PostRequest memory req = _request(BOUNTY);
        req.acceptWindow = uint64(market.MIN_WINDOW()) - 1;
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.WindowOutOfRange.selector, req.acceptWindow));
        market.postJob(req);

        req = _request(BOUNTY);
        req.reviewWindow = uint64(market.MAX_WINDOW()) + 1;
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.WindowOutOfRange.selector, req.reviewWindow));
        market.postJob(req);
    }

    function test_unknownJobAndReceipt() public {
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.UnknownJob.selector, 0));
        market.getJob(0);
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.UnknownReceipt.selector, 1));
        market.getReceipt(1);
        assertEq(market.getReceipts(1, 10).length, 0);
    }

    function test_pagination_capsPage() public {
        uint256 id = _post();
        uint256[] memory tooMany = new uint256[](51);
        for (uint256 i = 0; i < tooMany.length; ++i) {
            tooMany[i] = id;
        }
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.PageTooLarge.selector, 51));
        market.getJobs(tooMany);

        uint256[] memory one = new uint256[](1);
        one[0] = id;
        assertEq(market.getJobs(one)[0].poster, poster);
        assertEq(market.openJobIds(5, 10).length, 0);
        assertEq(market.posterJobIds(poster, 0, 10)[0], id);
    }

    function test_donation_isNotEscrow() public {
        usdt.mint(other, 7 ether);
        vm.prank(other);
        usdt.transfer(address(market), 7 ether);
        assertEq(market.escrowed(), 0);

        uint256 id = _submit();
        vm.prank(poster);
        market.approve(id);
        assertEq(market.escrowed(), 0);
        assertEq(usdt.balanceOf(address(market)), 7 ether);
        assertEq(usdt.balanceOf(worker), 95 ether);
    }

    function test_noReturnToken_happyPath() public {
        NoReturnToken token = new NoReturnToken();
        AgentJobMarket bare = new AgentJobMarket(address(token), address(registry), feeTo, FEE_BPS, 1 ether);
        token.mint(poster, BOUNTY);
        vm.prank(poster);
        token.approve(address(bare), BOUNTY);
        vm.prank(poster);
        uint256 id = bare.postJob(_request(BOUNTY));
        vm.prank(worker);
        bare.accept(id);
        vm.prank(worker);
        bare.submit(id, keccak256("nr"), "");
        vm.prank(poster);
        bare.approve(id);
        assertEq(token.balanceOf(worker), 95 ether);
        assertEq(token.balanceOf(feeTo), 5 ether);
        assertEq(token.balanceOf(address(bare)), 0);
    }

    function test_shortingToken_escrowsWhatArrived_andWillNotLieOnTheWayOut() public {
        ShortingToken token = new ShortingToken(9000);
        AgentJobMarket skim = new AgentJobMarket(address(token), address(registry), feeTo, 0, 1 ether);
        token.mint(poster, 100 ether);
        vm.prank(poster);
        token.approve(address(skim), 100 ether);

        vm.prank(poster);
        uint256 id = skim.postJob(_request(100 ether));
        assertEq(skim.getJob(id).bounty, 90 ether);
        assertEq(skim.escrowed(), 90 ether);
        assertEq(token.balanceOf(address(skim)), 90 ether);
        assertEq(token.balanceOf(poster), 0);

        uint256 posterBefore = token.balanceOf(poster);
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.FeeOnTransferOut.selector, poster, 90 ether, 81 ether));
        skim.cancel(id);

        assertEq(uint256(skim.getJob(id).status), uint256(AgentJobMarket.Status.Open));
        assertEq(skim.escrowed(), 90 ether);
        assertEq(token.balanceOf(poster), posterBefore);
        assertEq(token.balanceOf(address(skim)), 90 ether);
    }

    function test_reentrancyOnPull_cannotAcceptAnotherJob() public {
        ReentrantToken token = new ReentrantToken();
        AgentJobMarket trap = new AgentJobMarket(address(token), address(registry), feeTo, 0, 1 ether);
        vm.prank(address(token));
        registry.register("token");

        token.mint(poster, 100 ether);
        vm.prank(poster);
        token.approve(address(trap), type(uint256).max);

        vm.prank(poster);
        uint256 first = trap.postJob(_request(10 ether));
        token.configure(trap, first);
        token.setArmed(true);

        vm.prank(poster);
        vm.expectRevert(ReentrancyGuard.Reentrancy.selector);
        trap.postJob(_request(10 ether));

        assertEq(trap.jobCount(), 1);
        assertEq(trap.getJob(first).worker, address(0));
        assertEq(uint256(trap.getJob(first).status), uint256(AgentJobMarket.Status.Open));
        assertEq(trap.escrowed(), 10 ether);
        assertEq(token.balanceOf(address(trap)), 10 ether);
    }

    function test_mockRegistry_handleRules_andMainnetGuard() public {
        vm.expectRevert(MockAgentIdRegistry.InvalidHandle.selector);
        vm.prank(stranger);
        registry.register("Zap");

        vm.expectRevert(MockAgentIdRegistry.InvalidHandle.selector);
        vm.prank(stranger);
        registry.register("has.dot");

        vm.expectRevert(MockAgentIdRegistry.InvalidHandle.selector);
        vm.prank(stranger);
        registry.register("");

        vm.expectRevert(MockAgentIdRegistry.InvalidHandle.selector);
        vm.prank(stranger);
        registry.register(_repeat("a", 21));

        vm.prank(stranger);
        registry.register(_repeat("b", 20));
        assertEq(registry.handleOf(stranger), _repeat("b", 20));
        assertEq(registry.ownerOfHandle("Zap"), address(0));

        vm.expectRevert(MockAgentIdRegistry.AddressTaken.selector);
        vm.prank(stranger);
        registry.register("another");

        address second = makeAddr("second");
        vm.expectRevert(MockAgentIdRegistry.HandleTaken.selector);
        vm.prank(second);
        registry.register("poster");

        vm.chainId(56);
        vm.expectRevert(MockAgentIdRegistry.MainnetForbidden.selector);
        new MockAgentIdRegistry();
        vm.expectRevert(MockUSDT.MainnetForbidden.selector);
        new MockUSDT();
    }

    function test_mockUsdt_faucetCap() public {
        MockUSDT faucet = new MockUSDT();
        vm.prank(poster);
        faucet.faucet(1000 ether);
        assertEq(faucet.balanceOf(poster), 1000 ether);
        uint256 cap = faucet.FAUCET_CAP();
        vm.expectRevert(MockUSDT.CapExceeded.selector);
        vm.prank(poster);
        faucet.faucet(cap);
        assertTrue(faucet.isTestnetMock());
        assertTrue(registry.isTestnetMock());
    }

    function test_directJobLists_recordBothSides() public {
        uint256 id = _accept();
        assertEq(market.posterJobIds(poster, 0, 10)[0], id);
        assertEq(market.workerJobIds(worker, 0, 10)[0], id);
        assertEq(market.workerJobCount(poster), 0);
    }

    function _register(address account, string memory handle) internal {
        vm.prank(account);
        registry.register(handle);
    }

    function _request(uint256 bounty) internal pure returns (AgentJobMarket.PostRequest memory) {
        return AgentJobMarket.PostRequest({
            bounty: bounty,
            title: "Token safety audit",
            tag: "audit",
            specHash: keccak256("check the token"),
            specUri: "ipfs://spec",
            acceptWindow: WINDOW,
            submitWindow: WINDOW,
            reviewWindow: WINDOW
        });
    }

    function _post() internal returns (uint256 id) {
        vm.prank(poster);
        id = market.postJob(_request(BOUNTY));
    }

    function _accept() internal returns (uint256 id) {
        id = _post();
        vm.prank(worker);
        market.accept(id);
    }

    function _submit() internal returns (uint256 id) {
        id = _accept();
        _submitOn(id);
    }

    function _submitOn(uint256 id) internal {
        vm.prank(worker);
        market.submit(id, keccak256("audit report"), "ipfs://report");
    }

    function _dispute() internal returns (uint256 id) {
        id = _submit();
        vm.prank(poster);
        market.dispute(id, keccak256("needs another pass"));
    }

    function _repeat(string memory unit, uint256 count) internal pure returns (string memory out) {
        bytes memory piece = bytes(unit);
        bytes memory buf = new bytes(piece.length * count);
        for (uint256 i = 0; i < count; ++i) {
            for (uint256 j = 0; j < piece.length; ++j) {
                buf[i * piece.length + j] = piece[j];
            }
        }
        out = string(buf);
    }
}
