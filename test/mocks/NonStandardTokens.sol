// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice ERC20 that returns NO data on transfer/transferFrom (USDT-style).
contract NoReturnDataToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(address recipient, uint256 amount) {
        balanceOf[recipient] = amount;
    }

    function transfer(address to, uint256 value) external {
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        assembly {
            return(0, 0)
        }
    }

    function transferFrom(address from, address to, uint256 value) external {
        if (msg.sender != from) {
            allowance[from][msg.sender] -= value;
        }
        balanceOf[from] -= value;
        balanceOf[to] += value;
        assembly {
            return(0, 0)
        }
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        return true;
    }
}

/// @notice ERC20 that returns `false` on transfer (the "Token returns bool false" antipattern).
contract FalseReturnToken {
    mapping(address => uint256) public balanceOf;

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }
}

/// @notice ERC20 that reverts on transfer.
contract RevertingToken {
    function transfer(address, uint256) external pure returns (bool) {
        revert("nope");
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        revert("nope");
    }
}

/// @notice Receiver that rejects ETH (rejects transfer).
contract EthRejecter {
    receive() external payable {
        revert("no ETH please");
    }
}
