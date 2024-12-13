// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.20;

import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IRewardDistributor} from "./interfaces/IRewardDistributor.sol";

/*
    __________________________________
    ___  __ \__  ____/__  ____/__  __/
    __  / / /_  __/  __  /_   __  /   
    _  /_/ /_  /___  _  __/   _  /    
    /_____/ /_____/  /_/      /_/     

    Contracts Repository: (https://github.com/DeftFinance/smart-contracts/)
*/

/// @author @FarajiOranj, Founder of @DeftFinance
/// @title Staking
/// @notice Implementation of an APY staking pool. Users can deposit Deft token for a share in the pool. New shares depend of
/// current shares supply and DEFT in the pool.
contract DeftStaking is ERC20 {

    using SafeERC20 for IERC20;

    uint256 public constant CAMPAIGN_ID = 0;
    uint256 internal constant SHARES_FACTOR = 1e18;
    uint256 public constant MINIMUM_SHARES = 10 ** 3;

    IERC20 public immutable deftDexToken;
    IRewardDistributor public immutable rewardDistributor;

    struct UserInfo {
        uint256 lastBlockUpdate;
    }

    mapping(address => UserInfo) public userInfo;
    uint256 public totalShares;

    event Deposit(address user, uint depositAmount, uint shares);
    event Withdraw(address user, address recipient, uint withdrawAmount, uint shares);

    modifier checkUserBlock() {
        require(
            userInfo[msg.sender].lastBlockUpdate < block.number,
            "Staking::checkUserBlock::User already called deposit or withdraw this block"
        );
        userInfo[msg.sender].lastBlockUpdate = block.number;
        _;
    }

    constructor(IERC20 _deftDexToken, IRewardDistributor _rewardDistributor) ERC20("Staked DeftDex Token", "stDeft") {
        require(address(_deftDexToken) != address(0), "Staking::constructor::DeftDex token is not defined");
        require(address(_rewardDistributor) != address(0), "Staking::constructor::RewardDistributor is not defined");
        deftDexToken = _deftDexToken;
        rewardDistributor = _rewardDistributor;
    }

    //  /// @inheritdoc IStaking
    function deposit(uint256 _depositAmount) public checkUserBlock {
        require(_depositAmount != 0, "Staking::deposit::can't deposit zero token");

        redeemPreviousRewards();

        uint256 _currentBalance = deftDexToken.balanceOf(address(this));
        uint256 _newShares = _convertToShares(_depositAmount, _currentBalance);

        uint256 _userNewShares;
        if (totalShares == 0) {
            _userNewShares = _newShares - MINIMUM_SHARES;
        } else {
            _userNewShares = _newShares;
        }
        require(_userNewShares != 0, "Staking::deposit::no new shares received");
        totalShares += _newShares;

        deftDexToken.safeTransferFrom(msg.sender, address(this), _depositAmount);

        _mint(msg.sender, _newShares);

        emit Deposit(msg.sender, _depositAmount, _userNewShares);
    }

    //  /// @inheritdoc IStaking
    function withdraw(address _to, uint256 _sharesAmount) external checkUserBlock {
        require(
            _sharesAmount != 0,
            "Staking::withdraw::can't withdraw more than user shares or zero"
        );

        _burn(msg.sender, _sharesAmount);

        redeemPreviousRewards();

        uint256 _currentBalance = deftDexToken.balanceOf(address(this));
        uint256 _tokensToWithdraw = _convertToTokens(_sharesAmount, _currentBalance);

        totalShares -= _sharesAmount;
        deftDexToken.safeTransfer(_to, _tokensToWithdraw);

        emit Withdraw(msg.sender, _to, _tokensToWithdraw, _sharesAmount);
    }

    //  /// @inheritdoc IStaking
    function redeemPreviousRewards() public {
        rewardDistributor.withdraw(CAMPAIGN_ID, 0, address(this), address(this));
    }

    //  /// @inheritdoc IStaking
    function tokensToShares(uint256 _tokens) external view returns (uint256 shares_) {
        uint256 _currentBalance = deftDexToken.balanceOf(address(this));
        _currentBalance += rewardDistributor.pendingReward(CAMPAIGN_ID, address(this));

        shares_ = _convertToShares(_tokens, _currentBalance);
    }

    //  /// @inheritdoc IStaking
    function sharesToTokens(uint256 _shares) external view returns (uint256 tokens_) {
        uint256 _currentBalance = deftDexToken.balanceOf(address(this));
        _currentBalance += rewardDistributor.pendingReward(CAMPAIGN_ID, address(this));

        tokens_ = _convertToTokens(_shares, _currentBalance);
    }

    /**
     * @notice Calculate shares qty for an amount of deft tokens
     * @param _tokens user qty of deft to be converted to shares
     * @param _currentBalance contract balance deft. _tokens <= _currentBalance
     * @return shares_ shares equivalent to the token amount. _shares <= totalShares
     */
    function _convertToShares(uint256 _tokens, uint256 _currentBalance) internal view returns (uint256 shares_) {
        shares_ = totalShares != 0 ? (_tokens * totalShares) / _currentBalance : _tokens * SHARES_FACTOR;
    }

    /**
     * @notice Calculate shares values in deft tokens
     * @param _shares amount of shares. _shares <= totalShares
     * @param _currentBalance contract balance in deft
     * @return tokens_ qty of deft token equivalent to the _shares. tokens_ <= _currentBalance
     */
    function _convertToTokens(uint256 _shares, uint256 _currentBalance) internal view returns (uint256 tokens_) {
        tokens_ = totalShares != 0 ? (_shares * _currentBalance) / totalShares : _shares / SHARES_FACTOR;
    }
}
