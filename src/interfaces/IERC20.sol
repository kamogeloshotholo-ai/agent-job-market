// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal BEP-20 surface. Transfer return data is decoded by {SafeERC20}
///         so tokens that omit the bool (Binance-Peg USDT) still work.
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);

    function transfer(address to, uint256 amount) external returns (bool);

    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}
