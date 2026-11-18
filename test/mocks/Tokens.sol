// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAgentIdRegistry} from "../../src/interfaces/IAgentIdRegistry.sol";
import {AgentJobMarket} from "../../src/AgentJobMarket.sol";

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external virtual returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external virtual returns (bool) {
        _spend(from, amount);
        _transfer(from, to, amount);
        return true;
    }

    function _spend(address from, uint256 amount) internal {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

/// @dev Binance-Peg style: transfer and transferFrom return no bool.
contract NoReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev Debits the full amount and credits `rate` bps. Used to prove inbound
///      accounting and that outbound shorting cannot write a false receipt.
contract ShortingToken is MockERC20 {
    uint256 public rateBps;

    constructor(uint256 rateBps_) MockERC20("Short USDT", "sUSDT") {
        rateBps = rateBps_;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _short(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        _spend(from, amount);
        _short(from, to, amount);
        return true;
    }

    function _short(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount * rateBps / 10_000;
    }
}

/// @dev During transferFrom, accepts `attackJobId` on the market. The caller of
///      that accept is this token, so the test registers an Agent ID for it.
contract ReentrantToken is MockERC20 {
    AgentJobMarket public market;
    uint256 public attackJobId;
    bool public arm;

    constructor() MockERC20("Reentrant USDT", "rUSDT") {}

    function configure(AgentJobMarket market_, uint256 jobId) external {
        market = market_;
        attackJobId = jobId;
    }

    function setArmed(bool armed) external {
        arm = armed;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        _spend(from, amount);
        _transfer(from, to, amount);
        if (arm) {
            arm = false;
            market.accept(attackJobId);
        }
        return true;
    }
}

/// @dev Test double whose forward and reverse records can disagree.
contract ScriptedRegistry is IAgentIdRegistry {
    mapping(address => string) public names;
    mapping(bytes32 => address) public owners;

    function set(address account, string memory name, address forward) external {
        names[account] = name;
        owners[keccak256(bytes(name))] = forward;
    }

    function handleOf(address owner) external view returns (string memory) {
        return names[owner];
    }

    function ownerOfHandle(string calldata handle) external view returns (address) {
        return owners[keccak256(bytes(handle))];
    }
}
