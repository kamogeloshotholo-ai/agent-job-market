// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Single-lock reentrancy guard. The unlocked value is 1, not 0,
///         because storage defaults to 0 and that must not count as unlocked.
abstract contract ReentrancyGuard {
    error Reentrancy();

    uint256 private _locked = 1;

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }
}
