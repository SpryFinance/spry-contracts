// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Minimalist and gas efficient standard ERC6909 implementation.
/// @dev This contract is the modified version of ERC6909.
abstract contract ModifiedERC6909 {
    /********************************\
    |-*-*-*-*-*   STATES   *-*-*-*-*-|
    \********************************/
    mapping(bytes32 => uint256) private _totalSupply;
    mapping(bytes32 => mapping(address => uint256)) private _balanceOf;
    mapping(bytes32 => mapping(address => mapping(address => uint256)))
        private _allowance;

    /********************************\
    |-*-*-*-*-*   EVENTS   *-*-*-*-*-|
    \********************************/
    event Approval(
        bytes32 id,
        address indexed owner,
        address indexed spender,
        uint256 indexed amount
    );
    event Transfer(
        bytes32 id,
        address caller,
        address indexed from,
        address indexed to,
        uint256 indexed amount
    );

    /*******************************\
    |-*-*-*-*-*   LOGIC   *-*-*-*-*-|
    \*******************************/
    function approve(
        bytes32 id,
        address spender,
        uint256 amount
    ) external returns (bool) {
        _allowance[id][msg.sender][spender] = amount;

        emit Approval(id, msg.sender, spender, amount);

        return true;
    }

    function transfer(
        bytes32 id,
        address to,
        uint256 amount
    ) external returns (bool) {
        _balanceOf[id][msg.sender] -= amount;
        _balanceOf[id][to] += amount;

        emit Transfer(id, msg.sender, msg.sender, to, amount);

        return true;
    }

    function transferFrom(
        bytes32 id,
        address from,
        address to,
        uint256 amount
    ) public returns (bool) {
        if (msg.sender != from) {
            uint256 allowed = _allowance[id][from][msg.sender];
            if (allowed != type(uint256).max)
                _allowance[id][from][msg.sender] = allowed - amount;
        }

        _balanceOf[id][from] -= amount;
        _balanceOf[id][to] += amount;

        emit Transfer(id, msg.sender, from, to, amount);

        return true;
    }

    /******************************\
    |-*-*-*-*-*   VIEW   *-*-*-*-*-|
    \******************************/
    function allowance(
        bytes32 id,
        address owner,
        address spender
    ) external view returns (uint256) {
        return _allowance[id][owner][spender];
    }

    function balanceOf(bytes32 id, address owner)
        public
        view
        returns (uint256)
    {
        return _balanceOf[id][owner];
    }

    function totalSupply(bytes32 id) public view returns (uint256) {
        return _totalSupply[id];
    }

    /*******************************\
    |-*-*-*-*   INTERNALS   *-*-*-*-|
    \*******************************/
    function _mint(
        bytes32 id,
        address to,
        uint256 amount
    ) internal {
        _totalSupply[id] += amount;
        _balanceOf[id][to] += amount;

        emit Transfer(id, msg.sender, address(0), to, amount);
    }

    function _burn(
        bytes32 id,
        address from,
        uint256 amount
    ) internal {
        _balanceOf[id][from] -= amount;
        _totalSupply[id] -= amount;

        emit Transfer(id, msg.sender, from, address(0), amount);
    }
}
