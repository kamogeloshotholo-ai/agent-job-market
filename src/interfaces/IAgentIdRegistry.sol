// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IAgentIdRegistry
/// @notice Read interface for a Binance Agent ID (`name.ai`) registry.
/// @dev Confirmed against the SPACE ID docs (https://docs.space.id/agent-id) and
///      against BSC mainnet contract `0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F`
///      (chain 56, `name` = "SPACE ID Agent ID", `symbol` = "AI"):
///        - `handleOf(address)` selector `0xc50a1514`
///        - `ownerOfHandle(string)` selector `0x1da94fb4`
///      `ownerOfHandle` expects the bare handle (`zap`, not `zap.ai`) and does not
///      normalize case. `handleOf` returns "" when the address has no Agent ID.
///      `ownerOfHandle` returns `address(0)` when the handle is not registered.
///      The same address had no code on BSC testnet (chain 97). This interface
///      hardcodes no address — the market takes the registry in its constructor.
interface IAgentIdRegistry {
    /// @notice Documented registration event. Handles are permanent.
    event Registered(bytes32 indexed labelhash, address indexed owner, string handle);

    /// @notice Documented admin registration event. Also permanent.
    event AdminRegistered(bytes32 indexed labelhash, address indexed owner, string handle);

    /// @notice Reverse lookup. Empty string means the address has no Agent ID.
    function handleOf(address owner) external view returns (string memory);

    /// @notice Forward lookup. `address(0)` means the handle is not registered.
    function ownerOfHandle(string calldata handle) external view returns (address);
}
