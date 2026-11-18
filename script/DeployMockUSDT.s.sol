// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockUSDT} from "../src/mocks/MockUSDT.sol";

/// @notice Deploys a capped test USDT for BSC testnet demos. Not Tether.
///         The contract itself also reverts on chain 56. Prefer a real BEP-20
///         USDT address when you have test tokens for one.
contract DeployMockUSDT is Script {
    function run() external returns (MockUSDT usdt) {
        if (block.chainid == 56) revert("refusing to deploy mock USDT on BSC mainnet");
        if (block.chainid != 97 && block.chainid != 31_337) {
            revert(string.concat("unsupported chain ", vm.toString(block.chainid)));
        }

        vm.startBroadcast();
        usdt = new MockUSDT();
        vm.stopBroadcast();

        console2.log("MockUSDT", address(usdt));
        console2.log("chainId", block.chainid);
    }
}
