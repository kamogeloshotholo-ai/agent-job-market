// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title MockUSDT
/// @notice 18-decimal USDT stand-in for BSC testnet demos. Not Tether.
/// @dev The constructor refuses chain 56. `faucet` is capped per address so a
///      public testnet deployment cannot be minted without bound by one wallet.
contract MockUSDT {
    error MainnetForbidden();
    error CapExceeded();
    error ZeroAmount();
    error InsufficientBalance();
    error InsufficientAllowance();

    string public constant name = "Test USDT";
    string public constant symbol = "USDT";
    uint8 public constant decimals = 18;
    uint256 public constant FAUCET_CAP = 100_000 ether;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public mintedBy;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor() {
        if (block.chainid == 56) revert MainnetForbidden();
    }

    function isTestnetMock() external pure returns (bool) {
        return true;
    }

    function faucet(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        uint256 next = mintedBy[msg.sender] + amount;
        if (next > FAUCET_CAP) revert CapExceeded();
        mintedBy[msg.sender] = next;
        totalSupply += amount;
        balanceOf[msg.sender] += amount;
        emit Transfer(address(0), msg.sender, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (balanceOf[from] < amount) revert InsufficientBalance();
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
