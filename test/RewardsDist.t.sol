// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts@v4.9.3/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts@v4.9.3/utils/math/SafeCast.sol";

import {IYearnBoostedStaker} from "../src/interfaces/IYearnBoostedStaker.sol";

import {YearnBoostedStaker} from "../src/YearnBoostedStaker.sol";
import {SingleTokenRewardDistributor} from "../src/SingleTokenRewardDistributor.sol";

import "forge-std/Test.sol";
import "forge-std/console.sol";

contract RewardsDistTest is Test {

    using SafeCast for uint256;

    address public alice;
    address public bob;
    address public yossi;
    address public owner;

    YearnBoostedStaker public ybs;
    SingleTokenRewardDistributor public strd;

    uint256 public constant MAX_STAKE_GROWTH_WEEKS = 5;
    uint256 public constant START_TIME = 0;

    IERC20 public constant TOKEN = IERC20(0xFCc5c47bE19d06BF83eB04298b026F81069ff65b); // yCRV
    IERC20 public constant REWARD_TOKEN = IERC20(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E); // crvUSD


    function setUp() public {

        vm.selectFork(vm.createFork(vm.envString("ETH_RPC_URL")));

        alice = _createUser("alice");
        bob = _createUser("bob");
        yossi = _createUser("yossi");
        owner = _createUser("owner");

        deal({ token: address(REWARD_TOKEN), to: yossi, give: 1000 ether });

        ybs = new YearnBoostedStaker(
            address(TOKEN),
            MAX_STAKE_GROWTH_WEEKS,
            START_TIME,
            owner
        );

        strd = new SingleTokenRewardDistributor(IYearnBoostedStaker(address(ybs)), REWARD_TOKEN);
    }

    function _createUser(string memory _name) internal returns (address payable) {
        address payable _user = payable(makeAddr(_name));
        vm.deal({ account: _user, newBalance: 100 ether });
        deal({ token: address(TOKEN), to: _user, give: 1000 ether });
        return _user;
    }

    // ============================================================================================
    // Test Functions
    // ============================================================================================

    function testRewardsSetUp() public {
        assertEq(address(strd.staker()), address(ybs), "testRewardsSetUp: E0");
        assertEq(address(strd.rewardToken()), address(REWARD_TOKEN), "testRewardsSetUp: E1");
        assertEq(strd.START_WEEK(), ybs.getWeek(), "testRewardsSetUp: E2");
    }

    function testClaimRewardsSameDeposit() public {
        uint256 _amount = 1 ether;

        vm.startPrank(alice);
        TOKEN.approve(address(ybs), _amount);
        ybs.deposit(_amount);
        vm.stopPrank();

        vm.startPrank(bob);
        TOKEN.approve(address(ybs), _amount);
        ybs.deposit(_amount);
        vm.stopPrank();

        // deposit rewards
        vm.startPrank(yossi);
        REWARD_TOKEN.approve(address(strd), 1 ether);
        strd.depositReward(1 ether);
        vm.stopPrank();
    }
}