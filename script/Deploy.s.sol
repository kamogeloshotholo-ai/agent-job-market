// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {AgentJobMarket} from "../src/AgentJobMarket.sol";

/// @notice Deploys {AgentJobMarket}. The broadcaster is the CLI key (`--private-key`),
///         never an env read inside this script. Refuses chains other than BSC mainnet
///         (56), BSC testnet (97), and a local Anvil (31337).
contract DeployAgentJobMarket is Script {
    function run() external returns (AgentJobMarket market) {
        uint256 chainId = block.chainid;
        if (chainId != 56 && chainId != 97 && chainId != 31_337) {
            revert(string.concat("unsupported chain ", vm.toString(chainId)));
        }

        address usdt = vm.envAddress("USDT_ADDRESS");
        address registry = vm.envAddress("AGENT_ID_REGISTRY");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        uint256 feeBps = vm.envUint("FEE_BPS");
        uint256 minBounty = vm.envUint("MIN_BOUNTY");

        vm.startBroadcast();
        market = new AgentJobMarket(usdt, registry, feeRecipient, feeBps, minBounty);
        vm.stopBroadcast();

        console2.log("chainId", chainId);
        console2.log("AgentJobMarket", address(market));
        console2.log("USDT", usdt);
        console2.log("AgentIdRegistry", registry);
        console2.log("feeRecipient", feeRecipient);
        console2.log("feeBps", feeBps);
        console2.log("minBounty", minBounty);
    }
}
