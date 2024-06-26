// SPDX-License-Identifier: GNU AGPLv3
pragma solidity ^0.8.22;

import "./interfaces/IYearnBoostedStaker.sol";
import "./utils/WeekStart.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts@v4.9.3/token/ERC20/utils/SafeERC20.sol";


contract SingleTokenRewardDistributor is WeekStart {
    using SafeERC20 for IERC20;

    uint constant MAX_BPS = 10_000; // @audit - never used
    uint constant PRECISION = 1e18;
    IYearnBoostedStaker public immutable staker;
    IERC20 public immutable rewardToken;
    uint public immutable START_WEEK;

    struct AccountInfo {
        address recipient; // Who rewards will be sent to. Cheaper to store here than in dedicated mapping.
        uint96 lastClaimWeek;
    }

    mapping(uint week => uint amount) public weeklyRewardAmount;
    mapping(address account => AccountInfo info) public accountInfo;
    mapping(address account => mapping(address claimer => bool approved)) public approvedClaimer;
    
    event RewardDeposited(uint indexed week, address indexed depositor, uint rewardAmount);
    event RewardsClaimed(address indexed account, uint indexed week, uint rewardAmount);
    event RecipientConfigured(address indexed account, address indexed recipient);
    event ClaimerApproved(address indexed account, address indexed, bool approved);

    /**
        @notice Allow permissionless deposits to the current week. // @audit - wrong natspec
        @param _staker the staking contract to use for weight calculations.
        @param _rewardToken address of reward token.
    */
    constructor(
        IYearnBoostedStaker _staker,
        IERC20 _rewardToken
    )
        WeekStart(_staker) {
        staker = _staker;
        rewardToken = _rewardToken;
        START_WEEK = staker.getWeek();
    }

    /**
        @notice Allow permissionless deposits to the current week.
        @param _amount the amount of reward token to deposit.
    */
    function depositReward(uint _amount) external {
        _depositReward(msg.sender, _amount);
    }

    /**
        @notice Allow permissionless deposits to the current week from any address with approval.
        @param _target the address to pull tokens from.
        @param _amount the amount of reward token to deposit.
    */
    function depositRewardFrom(address _target, uint _amount) external {
        _depositReward(_target, _amount);
    }

    function _depositReward(address _target, uint _amount) internal {
        uint week = getWeek();

        if (_amount > 0) {
            rewardToken.transferFrom(_target, address(this), _amount); // @audit - use safeTransferFrom
            weeklyRewardAmount[week] += _amount; // @audit - not following CEI
            emit RewardDeposited(week, _target, _amount);
        }
    }

    /**
        @notice Claim all owed rewards since the last week touched by the user.
        @dev    It is not suggested to use this function directly. Rather `claimWithRange` 
                will tend to be more gas efficient when used with values from `getSuggestedClaimRange`.
    */
    function claim() external returns (uint amountClaimed) {
        uint currentWeek = getWeek();
        currentWeek = currentWeek == 0 ? 0 : currentWeek - 1;
        return _claimWithRange(msg.sender, 0, currentWeek);
    }

    /**
        @notice Claim on behalf of another account. Retrieves all owed rewards since the last week touched by the user.
        @dev    It is not suggested to use this function directly. Rather `claimWithRange` 
                will tend to be more gas efficient when used with values from `getSuggestedClaimRange`.
    */
    function claimFor(address _account) external returns (uint amountClaimed) {
        require(_onlyClaimers(_account), "!approvedClaimer");
        uint currentWeek = getWeek();
        currentWeek = currentWeek == 0 ? 0 : currentWeek - 1;
        return _claimWithRange(_account, 0, currentWeek);
    }

    /**
        @notice Claim rewards within a range of specified past weeks.
        @param _claimStartWeek the min week to search and rewards.
        @param _claimEndWeek the max week in which to search for an claim rewards.
        @dev    IMPORTANT: Choosing a `_claimStartWeek` that is greater than the earliest week in which a user
                may claim. Will result in the user being locked out (total loss) of rewards for any weeks prior.
    */
    function claimWithRange(
        uint _claimStartWeek,
        uint _claimEndWeek
    ) external returns (uint amountClaimed) {
        return _claimWithRange(msg.sender, _claimStartWeek, _claimEndWeek);
    }

    /**
        @notice Claim on behalf of another account for a range of specified past weeks.
        @param _account Account of which to make the claim on behalf of.
        @param _claimStartWeek The min week to search and rewards.
        @param _claimEndWeek The max week in which to search for an claim rewards.
        @dev    WARNING: Choosing a `_claimStartWeek` that is greater than the earliest week in which a user
                may claim will result in the user being locked out (total loss) of rewards for any weeks prior.
        @dev    Useful to target specific weeks with known reward amounts. Claiming via this function will tend 
                to be more gas efficient when used with values from `getSuggestedClaimRange`.
    */
    function claimWithRangeFor(
        address _account,
        uint _claimStartWeek,
        uint _claimEndWeek
    ) external returns (uint amountClaimed) {
        require(_onlyClaimers(_account), "!approvedClaimer");
        return _claimWithRange(_account, _claimStartWeek, _claimEndWeek);
    }

    function _claimWithRange(
        address _account,
        uint _claimStartWeek,
        uint _claimEndWeek
    ) internal returns (uint amountClaimed) {

        AccountInfo storage info = accountInfo[_account];
        uint currentWeek = getWeek();
        
        // Sanitize inputs
        uint _minStartWeek = info.lastClaimWeek == 0 ? START_WEEK : info.lastClaimWeek;
        _claimStartWeek = max(_minStartWeek, _claimStartWeek);
        
        require(_claimStartWeek <= _claimEndWeek, "claimStartWeek > claimEndWeek");
        require(_claimEndWeek < currentWeek, "claimEndWeek >= currentWeek");
        amountClaimed = _getTotalClaimableByRange(_account, _claimStartWeek, _claimEndWeek);
        
        _claimEndWeek += 1;
        info.lastClaimWeek = uint96(_claimEndWeek);
        address recipient = info.recipient == address(0) ? _account : info.recipient;
        
        if (amountClaimed > 0) {
            rewardToken.transfer(recipient, amountClaimed); // @audit - use safeTransfer
            emit RewardsClaimed(_account, _claimEndWeek, amountClaimed); // @audit - consider treating emit as state change and apply CEI
        }
    }

    // @audit - natspec missing params
    /**
        @notice Helper function used to determine overal share of rewards at a particular week.
        @dev    Computing shares in past weeks is accurate. However, current week computations will not accurate 
                as week the is not yet finalized.
        @dev    Results scaled to PRECSION.
    */
    function computeSharesAt(address _account, uint _week) public view returns (uint rewardShare) {
        require(_week <= getWeek(), "Invalid week");
        uint acctWeight = staker.getAccountWeightAt(_account, _week);
        if (acctWeight == 0) return 0; // User has no weight.
        uint globalWeight = staker.getGlobalWeightAt(_week);
        return acctWeight * PRECISION / globalWeight;
    }

    // @audit - natspec missing params
    /**
        @notice Get the sum total number of claimable tokens for a user across all his claimable weeks.
    */
    function claimable(address _account) external view returns (uint claimable) { // @audit - `claimable` shadows function name
        (uint claimStartWeek, uint claimEndWeek) = getSuggestedClaimRange(_account);
        return _getTotalClaimableByRange(_account, claimStartWeek, claimEndWeek);
    }

    // @audit - natspec missing params
    /**
        @dev Returns sum of tokens earned with the specified range of weeks.
    */
    function getTotalClaimableByRange(
        address _account,
        uint _claimStartWeek,
        uint _claimEndWeek
    ) external view returns (uint claimable) { // @audit - `claimable` shadows function name
        uint currentWeek = getWeek();
        if (_claimEndWeek > currentWeek) _claimEndWeek = currentWeek;
        return _getTotalClaimableByRange(_account, _claimStartWeek, _claimEndWeek);
    }

    function _getTotalClaimableByRange(
        address _account,
        uint _claimStartWeek,
        uint _claimEndWeek
    ) internal view returns (uint claimableAmount) {
        for (uint i = _claimStartWeek; i <= _claimEndWeek; ++i) {
            uint claimable = getClaimableAt(_account, i); // @audit - `claimable` shadows function name
            claimableAmount += claimable; // @audit - can += directly
        }
    }

    // @audit - natspec missing params
    /**
        @notice Helper function returns suggested start and end range for claim weeks.
        @dev    This function is designed to be called prior to ranged claims to shorted the number of iterations
                required to loop if possible.
    */
    function getSuggestedClaimRange(address _account) public view returns (uint claimStartWeek, uint claimEndWeek) {
        uint currentWeek = getWeek();
        if (currentWeek == 0) return (0, 0);
        bool canClaim;
        uint lastClaimWeek = accountInfo[_account].lastClaimWeek;
        
        claimStartWeek = START_WEEK > lastClaimWeek ? START_WEEK : lastClaimWeek;

        // Loop from old towards recent.
        for (claimStartWeek; claimStartWeek <= currentWeek; claimStartWeek++) {
            if (getClaimableAt(_account, claimStartWeek) > 0) {
                canClaim = true;
                break;
            }
        }

        if (!canClaim) return (0,0);

        // Loop backwards from recent week towards old. Skip current week.
        for (claimEndWeek = currentWeek - 1; claimEndWeek > claimStartWeek; claimEndWeek--) {
            if (getClaimableAt(_account, claimEndWeek) > 0) {
                break;
            }
        }

        return (claimStartWeek, claimEndWeek);
    }

    /**
        @notice Get the reward amount available at a given week index.
        @param _account The account to check.
        @param _week The past week to check.
    */
    function getClaimableAt(
        address _account, 
        uint _week
    ) public view returns (uint rewardAmount) {
        uint currentWeek = getWeek(); // @audit - can save local variable and use getWeek() directly
        if(_week >= currentWeek) return 0;
        if(_week < accountInfo[_account].lastClaimWeek) return 0;
        uint rewardShare = computeSharesAt(_account, _week);
        uint totalWeeklyAmount = weeklyRewardAmount[_week];
        rewardAmount = rewardShare * totalWeeklyAmount / PRECISION;
    }

    function _onlyClaimers(address _account) internal returns (bool approved) { // @audit - should be view
        return approvedClaimer[_account][msg.sender] || _account == msg.sender;
    }

    /**
        @notice User may configure their account to set a custom reward recipient.
        @param _recipient   Wallet to receive rewards on behalf of the account. Zero address will result in all 
                            rewards being transferred directly to the account holder.
    */
    function configureRecipient(address _recipient) external {
        accountInfo[msg.sender].recipient = _recipient;
        emit RecipientConfigured(msg.sender, _recipient);
    }

    /**
        @notice Allow account to specify addresses to claim on their behalf.
        @param _claimer Claimer to approve or revoke
        @param _approved True to approve, False to revoke.
    */
    function approveClaimer(address _claimer, bool _approved) external {
        approvedClaimer[msg.sender][_claimer] = _approved;
        emit ClaimerApproved(msg.sender, _claimer, _approved);
    }

    function max(uint a, uint b) internal pure returns (uint) {
        return a < b ? b : a;
    }
}