// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "../interfaces/IERC20.sol";

/// @notice Transfer helper that accepts both bool-returning and no-return BEP-20s.
///         A `false` return or a revert both fail the call. Empty return data is success.
library SafeERC20 {
    error SafeERC20Failed();

    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        _call(address(token), abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        _call(address(token), abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount));
    }

    function _call(address token, bytes memory data) private {
        (bool success, bytes memory returndata) = token.call(data);
        if (!success) {
            if (returndata.length > 0) {
                assembly {
                    revert(add(returndata, 32), mload(returndata))
                }
            }
            revert SafeERC20Failed();
        }
        if (returndata.length == 0) return;
        if (abi.decode(returndata, (bool))) return;
        revert SafeERC20Failed();
    }
}
