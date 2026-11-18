// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AgentJobMarket} from "../src/AgentJobMarket.sol";
import {FeeMath} from "../src/libraries/FeeMath.sol";
import {MockAgentIdRegistry} from "../src/mocks/MockAgentIdRegistry.sol";
import {MockERC20} from "./mocks/Tokens.sol";

contract AgentJobMarketFuzzTest is Test {
    MockAgentIdRegistry internal registry;
    MockERC20 internal usdt;
    AgentJobMarket internal market;

    address internal poster = makeAddr("poster");
    address internal worker = makeAddr("worker");
    address internal feeTo = makeAddr("fee");

    function setUp() public {
        registry = new MockAgentIdRegistry();
        usdt = new MockERC20("Mock USDT", "USDT");
        market = new AgentJobMarket(address(usdt), address(registry), feeTo, 500, 1 ether);
        vm.prank(poster);
        registry.register("poster");
        vm.prank(worker);
        registry.register("worker");
        usdt.mint(poster, type(uint128).max);
        vm.prank(poster);
        usdt.approve(address(market), type(uint256).max);
    }

    function testFuzz_quoteConservesBounty(uint128 bounty, uint16 workerBps, uint16 rawFee) public {
        uint256 bps = bound(workerBps, 0, 10_000);
        uint256 feeBps = bound(rawFee, 0, 500);
        MockERC20 token = new MockERC20("Fuzz USDT", "fUSDT");
        MockAgentIdRegistry reg = new MockAgentIdRegistry();
        AgentJobMarket probed = new AgentJobMarket(address(token), address(reg), feeTo, feeBps, 0);

        (uint256 workerNet, uint256 posterRefund, uint256 fee) = probed.quote(bounty, bps);
        assertEq(workerNet + posterRefund + fee, uint256(bounty));
        assertLe(fee, uint256(bounty));
        assertLe(probed.feeBps(), probed.MAX_FEE_BPS());

        (uint256 againNet, uint256 againRefund, uint256 againFee) = FeeMath.quote(bounty, bps, feeBps);
        assertEq(againNet, workerNet);
        assertEq(againRefund, posterRefund);
        assertEq(againFee, fee);
    }

    function testFuzz_quoteRejectsShareAboveFull(uint128 bounty, uint256 workerBps) public {
        workerBps = bound(workerBps, 10_001, type(uint64).max);
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.SplitOutOfRange.selector, workerBps));
        market.quote(bounty, workerBps);
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_happyPathConservesFunds(uint96 rawBounty) public {
        uint256 bounty = bound(rawBounty, 1 ether, 1_000_000 ether);
        uint256 posterBefore = usdt.balanceOf(poster);

        vm.prank(poster);
        uint256 id = market.postJob(_request(bounty));
        vm.prank(worker);
        market.accept(id);
        vm.prank(worker);
        market.submit(id, keccak256(abi.encode(bounty, id)), "ipfs://fuzz");
        vm.prank(poster);
        market.approve(id);

        (uint256 workerNet, uint256 posterRefund, uint256 fee) = market.quote(bounty, market.BPS());
        AgentJobMarket.Receipt memory receipt = market.getReceipt(market.receiptOfJob(id));
        assertEq(receipt.posterName, "poster");
        assertEq(receipt.workerName, "worker");
        assertEq(receipt.workerPayout, workerNet);
        assertEq(receipt.posterRefund, posterRefund);
        assertEq(receipt.protocolFee, fee);
        assertEq(workerNet + posterRefund + fee, bounty);
        assertEq(usdt.balanceOf(worker), workerNet);
        assertEq(usdt.balanceOf(feeTo), fee);
        assertEq(usdt.balanceOf(poster), posterBefore - bounty);
        assertEq(market.escrowed(), 0);
        assertEq(usdt.balanceOf(address(market)), 0);
    }

    /// forge-config: default.fuzz.runs = 48
    function testFuzz_splitConservesFunds(uint96 rawBounty, uint16 rawShare) public {
        uint256 bounty = bound(rawBounty, 1 ether, 250_000 ether);
        uint256 share = bound(rawShare, 0, 10_000);
        uint256 posterBefore = usdt.balanceOf(poster);
        uint256 workerBefore = usdt.balanceOf(worker);
        uint256 feeBefore = usdt.balanceOf(feeTo);

        vm.prank(poster);
        uint256 id = market.postJob(_request(bounty));
        vm.prank(worker);
        market.accept(id);
        vm.prank(worker);
        market.submit(id, keccak256("split"), "");
        vm.prank(poster);
        market.dispute(id, keccak256("split"));
        vm.prank(poster);
        market.proposeSplit(id, share);
        vm.prank(worker);
        market.proposeSplit(id, share);

        (uint256 workerNet, uint256 posterRefund, uint256 fee) = market.quote(bounty, share);
        assertEq(workerNet + posterRefund + fee, bounty);
        assertEq(usdt.balanceOf(worker), workerBefore + workerNet);
        assertEq(usdt.balanceOf(poster), posterBefore - bounty + posterRefund);
        assertEq(usdt.balanceOf(feeTo), feeBefore + fee);
        assertEq(market.escrowed(), 0);
        assertEq(usdt.balanceOf(address(market)), 0);
        assertEq(market.getReceipt(market.receiptOfJob(id)).posterName, "poster");
        assertEq(market.getReceipt(market.receiptOfJob(id)).workerName, "worker");
    }

    function testFuzz_rejectsWindow(uint64 window) public {
        vm.assume(window < market.MIN_WINDOW() || window > market.MAX_WINDOW());
        AgentJobMarket.PostRequest memory req = _request(1 ether);
        req.acceptWindow = window;
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.WindowOutOfRange.selector, window));
        market.postJob(req);
    }

    function testFuzz_acceptsWindow(uint64 acceptWindow, uint64 submitWindow, uint64 reviewWindow) public {
        acceptWindow = uint64(bound(acceptWindow, market.MIN_WINDOW(), market.MAX_WINDOW()));
        submitWindow = uint64(bound(submitWindow, market.MIN_WINDOW(), market.MAX_WINDOW()));
        reviewWindow = uint64(bound(reviewWindow, market.MIN_WINDOW(), market.MAX_WINDOW()));

        AgentJobMarket.PostRequest memory req = _request(1 ether);
        req.acceptWindow = acceptWindow;
        req.submitWindow = submitWindow;
        req.reviewWindow = reviewWindow;

        vm.prank(poster);
        uint256 id = market.postJob(req);
        AgentJobMarket.Job memory job = market.getJob(id);
        assertEq(job.acceptBy, uint64(block.timestamp) + acceptWindow);
        assertEq(job.submitWindow, submitWindow);
        assertEq(job.reviewWindow, reviewWindow);
        assertEq(job.posterName, "poster");
    }

    function testFuzz_nonAgentCannotPost(address account) public {
        vm.assume(account != poster && account != worker);
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(AgentJobMarket.NoAgentId.selector, account));
        market.postJob(_request(1 ether));
    }

    function _request(uint256 bounty) internal pure returns (AgentJobMarket.PostRequest memory) {
        return AgentJobMarket.PostRequest({
            bounty: bounty,
            title: "Token safety audit",
            tag: "audit",
            specHash: keccak256("check the token"),
            specUri: "",
            acceptWindow: 1 hours,
            submitWindow: 1 hours,
            reviewWindow: 1 hours
        });
    }
}
