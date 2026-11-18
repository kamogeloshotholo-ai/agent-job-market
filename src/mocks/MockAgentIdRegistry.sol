// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAgentIdRegistry} from "../interfaces/IAgentIdRegistry.sol";

/// @title MockAgentIdRegistry
/// @notice Testnet and local stand-in for the SPACE ID Agent ID registry.
/// @dev NOT the mainnet registry. The constructor refuses chain 56. Handles follow
///      the live rules that were observed and documented: 1 to 20 bytes, lowercase
///      `a-z` and `0-9`, no `.ai` suffix, one handle per address, one address per
///      handle. Anyone may register a handle for themselves so a testnet demo can
///      run before an official testnet registry exists. Do not point a mainnet
///      market at this contract.
contract MockAgentIdRegistry is IAgentIdRegistry {
    error MainnetForbidden();
    error InvalidHandle();
    error HandleTaken();
    error AddressTaken();

    uint256 public constant MAX_LEN = 20;

    mapping(address => string) private _handleOf;
    mapping(bytes32 => address) private _ownerOf;

    constructor() {
        if (block.chainid == 56) revert MainnetForbidden();
    }

    /// @notice The app uses this to show a "register a test handle" form.
    ///         The real SPACE ID registry has no such function.
    function isTestnetMock() external pure returns (bool) {
        return true;
    }

    function register(string calldata handle) external returns (bytes32 labelhash) {
        bytes memory raw = bytes(handle);
        uint256 len = raw.length;
        if (len == 0 || len > MAX_LEN) revert InvalidHandle();
        for (uint256 i = 0; i < len; ++i) {
            bytes1 c = raw[i];
            bool digit = c >= 0x30 && c <= 0x39;
            bool lower = c >= 0x61 && c <= 0x7a;
            if (!digit && !lower) revert InvalidHandle();
        }

        if (bytes(_handleOf[msg.sender]).length != 0) revert AddressTaken();
        labelhash = keccak256(raw);
        if (_ownerOf[labelhash] != address(0)) revert HandleTaken();

        _handleOf[msg.sender] = handle;
        _ownerOf[labelhash] = msg.sender;
        emit Registered(labelhash, msg.sender, handle);
    }

    function handleOf(address owner) external view returns (string memory) {
        return _handleOf[owner];
    }

    function ownerOfHandle(string calldata handle) external view returns (address) {
        return _ownerOf[keccak256(bytes(handle))];
    }
}
