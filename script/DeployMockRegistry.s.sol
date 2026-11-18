// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockAgentIdRegistry} from "../src/mocks/MockAgentIdRegistry.sol";

/// @notice Deploys the testnet Agent ID stand-in. The contract itself also
///         reverts on chain 56. There is no published SPACE ID Agent ID registry
///         on BSC testnet; do not invent one.
contract DeployMockRegistry is Script {
    function run() external returns (MockAgentIdRegistry registry) {
        if (block.chainid == 56) revert("refusing to deploy the mock registry on BSC mainnet");
        if (block.chainid != 97 && block.chainid != 31_337) {
            revert(string.concat("unsupported chain ", vm.toString(block.chainid)));
        }

        vm.startBroadcast();
        registry = new MockAgentIdRegistry();
        vm.stopBroadcast();

        console2.log("MockAgentIdRegistry", address(registry));
        console2.log("chainId", block.chainid);
    }
}
