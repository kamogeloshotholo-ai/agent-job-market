// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Integer fee split. The worker's gross is `bounty * workerBps / 10_000`.
///         The protocol fee is that gross times `feeBps / 10_000`, rounded down.
///         Dust stays with the worker. The three outputs always sum to `bounty`
///         when `workerBps` and `feeBps` are within range.
library FeeMath {
    uint256 internal constant BPS = 10_000;

    function quote(uint256 bounty, uint256 workerBps, uint256 feeBps)
        internal
        pure
        returns (uint256 workerNet, uint256 posterRefund, uint256 fee)
    {
        uint256 workerGross = (bounty * workerBps) / BPS;
        posterRefund = bounty - workerGross;
        fee = (workerGross * feeBps) / BPS;
        workerNet = workerGross - fee;
    }
}
