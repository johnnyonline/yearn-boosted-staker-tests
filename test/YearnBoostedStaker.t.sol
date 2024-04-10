// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts@v4.9.3/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts@v4.9.3/utils/math/SafeCast.sol";

import "forge-std/Test.sol";
import "forge-std/console.sol";

import {YearnBoostedStaker} from "../src/YearnBoostedStaker.sol";

// NOTES:
// concert to binary - `cast to-base $NUMBER 2`
// concert to base 10 - `cast to-base $BIN_NUMBER 10` (0b100000)

struct BeforeDepositData {
    uint112 realizedStake;
    uint112 pendingStake;
    uint16 lastUpdateWeek;
    uint8 updateWeeksBitmap;
    uint256 userBalance;
    uint256 ybsBalance;
    uint112 globalGrowthRate;
    uint256 accountWeeklyToRealize;
    uint256 accountWeeklyWeights;
    uint256 globalWeeklyToRealize;
    uint256 globalWeeklyWeights;
    uint256 totalSupply;
}

contract YearnBoostedStakerTest is Test {

    using SafeCast for uint256;

    address public alice;
    address public bob;
    address public yossi;
    address public owner;

    YearnBoostedStaker public ybs;

    uint256 public constant MAX_STAKE_GROWTH_WEEKS = 5;
    uint256 public constant START_TIME = 0; // todo

    IERC20 public constant TOKEN = IERC20(0xFCc5c47bE19d06BF83eB04298b026F81069ff65b);

    function setUp() public {

        vm.selectFork(vm.createFork(vm.envString("ETH_RPC_URL")));

        alice = _createUser("alice");
        bob = _createUser("bob");
        yossi = _createUser("yossi");
        owner = _createUser("owner");

        ybs = new YearnBoostedStaker(
            address(TOKEN),
            MAX_STAKE_GROWTH_WEEKS,
            START_TIME,
            owner
        );
    }

    // ============================================================================================
    // Test Functions
    // ============================================================================================

    function testDeploymentsParams() public view {
        assertEq(ybs.owner(), owner, "testDeploymentsParams: E0");
        assertEq(address(ybs.stakeToken()), address(TOKEN), "testDeploymentsParams: E1");
        assertEq(ybs.decimals(), 18, "testDeploymentsParams: E2");
        assertEq(ybs.MAX_STAKE_GROWTH_WEEKS(), MAX_STAKE_GROWTH_WEEKS, "testDeploymentsParams: E3");
        assertEq(ybs.MAX_WEEK_BIT(), 32, "testDeploymentsParams: E4"); // 32 = 0b100000 --> 5 weeks
        assertEq(ybs.START_TIME(), block.timestamp, "testDeploymentsParams: E5");
    }

    function testImmediateWithdrawalFlow(uint256 _amount) public {
        vm.assume(_amount > 1 && _amount < 1000 ether && _amount < type(uint112).max);
        _initialUserDeposit(alice, _amount);

        // check that if we withdraw the same amount we deposited, we get the same amount back
    }

    // ============================================================================================
    // Internal Functions
    // ============================================================================================

    function _initialUserDeposit(address _user, uint256 _amount) internal {

        BeforeDepositData memory _beforeDepositData;
        {
            (
                uint112 _realizedStakeBefore,
                uint112 _pendingStakeBefore,
                uint16 _lastUpdateWeekBefore,
                uint8 _updateWeeksBitmapBefore
            ) = ybs.accountData(_user);

            _beforeDepositData = BeforeDepositData({
                realizedStake: _realizedStakeBefore,
                pendingStake: _pendingStakeBefore,
                lastUpdateWeek: _lastUpdateWeekBefore,
                updateWeeksBitmap: _updateWeeksBitmapBefore,
                userBalance: TOKEN.balanceOf(_user),
                ybsBalance: TOKEN.balanceOf(address(ybs)),
                globalGrowthRate: ybs.globalGrowthRate(),
                accountWeeklyToRealize: ybs.accountWeeklyToRealize(_user, ybs.getWeek() + MAX_STAKE_GROWTH_WEEKS),
                accountWeeklyWeights: ybs.getAccountWeightAt(_user, ybs.getWeek()),
                globalWeeklyToRealize: ybs.globalWeeklyToRealize(ybs.getWeek() + MAX_STAKE_GROWTH_WEEKS),
                globalWeeklyWeights: ybs.getGlobalWeightAt(ybs.getWeek()),
                totalSupply: ybs.totalSupply()
            });
        }

        vm.startPrank(_user);
        TOKEN.approve(address(ybs), _amount);
        ybs.deposit(_amount);

        (
            uint112 _realizedStakeAfter,
            uint112 _pendingStakeAfter,
            uint16 _lastUpdateWeekAfter,
            uint8 _updateWeeksBitmapAfter
        ) = ybs.accountData(_user);

        uint256 _weight = _amount >> 1;
        assertEq(_weight, _amount / 2, "_deposit: E0"); // `weight = amount / 2` because of 0.5x multiplier
        assertEq(_realizedStakeAfter, _beforeDepositData.realizedStake, "_deposit: E1");
        assertEq(_pendingStakeAfter, _beforeDepositData.pendingStake + _weight.toUint112(), "_deposit: E2");
        assertEq(_lastUpdateWeekAfter, ybs.getWeek(), "_deposit: E3");
        if (_beforeDepositData.updateWeeksBitmap == 0) {
            assertEq(_updateWeeksBitmapAfter, 1, "_deposit: E4");
        } else {
            assertEq(_updateWeeksBitmapAfter, _beforeDepositData.updateWeeksBitmap, "_deposit: E5");
        }
        assertApproxEqAbs(TOKEN.balanceOf(_user), _beforeDepositData.userBalance - _amount, 1, "_deposit: E6");
        assertApproxEqAbs(TOKEN.balanceOf(address(ybs)), _beforeDepositData.ybsBalance + _amount, 1, "_deposit: E7");
        assertEq(ybs.globalGrowthRate(), _beforeDepositData.globalGrowthRate + _weight.toUint112(), "_deposit: E8");
        assertEq(ybs.accountWeeklyToRealize(_user, ybs.getWeek() + MAX_STAKE_GROWTH_WEEKS), _beforeDepositData.accountWeeklyToRealize + _weight, "_deposit: E9");
        assertEq(ybs.getAccountWeightAt(_user, ybs.getWeek()), _beforeDepositData.accountWeeklyWeights + _weight, "_deposit: E10");
        assertEq(ybs.globalWeeklyToRealize(ybs.getWeek() + MAX_STAKE_GROWTH_WEEKS), _beforeDepositData.globalWeeklyToRealize + _weight, "_deposit: E11");
        assertEq(ybs.getGlobalWeightAt(ybs.getWeek()), _beforeDepositData.globalWeeklyWeights + _weight, "_deposit: E12");
        assertApproxEqAbs(ybs.totalSupply(), _beforeDepositData.totalSupply + _amount, 1, "_deposit: E13");
        assertApproxEqAbs((_realizedStakeAfter + _pendingStakeAfter) * 2, _beforeDepositData.realizedStake + _beforeDepositData.pendingStake + _amount.toUint112(), 1, "_deposit: E14");
    }

    function _createUser(string memory _name) internal returns (address payable) {
        address payable _user = payable(makeAddr(_name));
        vm.deal({ account: _user, newBalance: 100 ether });
        deal({ token: address(TOKEN), to: _user, give: 1000 ether });
        return _user;
    }
}
