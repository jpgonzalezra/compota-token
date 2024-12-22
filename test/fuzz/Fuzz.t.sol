// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.23;

import { Test } from "forge-std/Test.sol";
import { Compota } from "../../src/Compota.sol";
import { ICompota } from "../../src/interfaces/ICompota.sol";
import { MockLPToken } from "../Compota.t.sol";
// import { console } from "forge-std/console.sol";

contract FuzzTests is Test {
    Compota token;
    address owner = address(this);
    address alice = address(0x2);
    address bob = address(0x3);

    MockLPToken lpToken;

    uint16 constant INTEREST_RATE = 1000; // 10% APY
    uint256 constant INITIAL_MINT = 1000 * 10 ** 6;
    uint256 constant MAX_SUPPLY = 1_000_000_000e6;

    function setUp() public {
        vm.startPrank(owner);
        token = new Compota(INTEREST_RATE, 1 days, 1_000_000_000e6);
        lpToken = new MockLPToken(address(token), address(0));

        vm.stopPrank();
    }

    function testFuzzMint(address to, uint256 amount) public {
        vm.assume(to != address(0));
        vm.assume(amount > 0);
        vm.assume(amount <= 1e24);

        uint256 currentSupply = token.totalSupply();
        uint256 remainingSupply = MAX_SUPPLY - currentSupply;

        if (amount > remainingSupply) {
            amount = remainingSupply;
        }

        vm.prank(owner);
        token.mint(to, amount);

        assertEq(token.balanceOf(to), amount);
        assertEq(token.totalSupply(), amount);
    }

    function testFuzzBurn(uint256 amount) public {
        vm.prank(owner);

        token.mint(alice, INITIAL_MINT);
        vm.assume(amount > 0);
        vm.assume(amount <= INITIAL_MINT);

        vm.prank(alice);
        token.burn(amount);

        assertEq(token.balanceOf(alice), INITIAL_MINT - amount);
        assertEq(token.totalSupply(), INITIAL_MINT - amount);
    }

    function testFuzzBurnWithInterest(uint256 amount) public {
        vm.prank(owner);
        token.mint(alice, INITIAL_MINT);

        vm.assume(amount > 0);
        vm.assume(amount <= INITIAL_MINT);

        vm.warp(block.timestamp + 20 days);

        uint256 expectedInterest = (INITIAL_MINT * INTEREST_RATE * 20 days) / (10_000 * 365 days);

        vm.prank(alice);
        token.claimRewards();

        vm.prank(alice);
        token.burn(amount);

        assertEq(token.balanceOf(alice), (INITIAL_MINT + expectedInterest) - amount);
        assertEq(token.totalSupply(), (INITIAL_MINT + expectedInterest) - amount);
    }

    function testFuzzTransfer(address to, uint256 amount) public {
        vm.assume(to != address(0));
        vm.assume(to != alice);
        vm.assume(amount <= INITIAL_MINT);

        vm.prank(owner);
        token.mint(alice, INITIAL_MINT);

        vm.prank(alice);
        token.transfer(to, amount);

        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(alice), INITIAL_MINT - amount);
    }

    function testFuzzUpdateRewards(address account) public {
        vm.assume(account != address(0));

        vm.prank(owner);
        token.mint(account, INITIAL_MINT);

        vm.warp(block.timestamp + 180 days);

        vm.prank(account);
        token.claimRewards();

        uint256 expectedRewards = (INITIAL_MINT * INTEREST_RATE * 180 days) / (10_000 * 365 days);
        assertEq(token.balanceOf(account), INITIAL_MINT + expectedRewards);
    }

    function testFuzzSetYearlyRate(uint16 newRate) public {
        vm.prank(owner);

        if (newRate < token.MIN_YEARLY_RATE() || newRate > token.MAX_YEARLY_RATE()) {
            vm.expectRevert(abi.encodeWithSelector(ICompota.InvalidYearlyRate.selector, newRate));
            token.setYearlyRate(newRate);
        } else {
            uint16 oldRate = token.yearlyRate();

            vm.expectEmit(true, true, true, true);
            emit ICompota.YearlyRateUpdated(oldRate, newRate);

            token.setYearlyRate(newRate);

            assertEq(token.yearlyRate(), newRate);
        }
    }

    function testFuzzCalculateBaseRewards(address account, uint256 mintAmount, uint32 warpTime) public {
        vm.assume(account != address(0));
        vm.assume(mintAmount > 0 && mintAmount < MAX_SUPPLY);
        vm.assume(warpTime > block.timestamp);

        vm.prank(owner);
        token.mint(account, mintAmount);
        uint32 initialTimestamp = uint32(block.timestamp);

        vm.warp(warpTime);

        uint256 calculatedBaseRewards = token.calculateBaseRewards(account, uint32(block.timestamp));

        uint256 elapsedTime = uint32(block.timestamp) - initialTimestamp;
        uint256 expectedBaseRewards = (mintAmount * INTEREST_RATE * elapsedTime) / (10_000 * 365 days);

        assertEq(calculatedBaseRewards, expectedBaseRewards, "Base rewards calculation mismatch");
    }

    function testFuzzCalculateStakingRewards(
        address account,
        uint256 lpAmount,
        uint32 warpTime,
        uint112 reserve0,
        uint112 reserve1
    ) public {
        vm.assume(account != address(0));
        vm.assume(lpAmount >= 1e6 && lpAmount < MAX_SUPPLY);
        vm.assume(warpTime > block.timestamp);
        vm.assume(reserve0 > 0 && reserve1 > 0);

        vm.prank(owner);
        token.addStakingPool(address(lpToken), 2e6, 365 days);

        vm.prank(owner);
        lpToken.mint(account, lpAmount);
        assertEq(lpToken.balanceOf(account), lpAmount);

        lpToken.setReserves(reserve0, reserve1);

        vm.prank(account);
        lpToken.approve(address(token), lpAmount);
        assertEq(lpToken.allowance(account, address(token)), lpAmount);

        vm.prank(account);
        token.stakeLiquidity(0, lpAmount);

        uint32 initialTimestamp = uint32(block.timestamp);

        vm.warp(warpTime);
        uint32 timestampAfterWarpTime = uint32(block.timestamp);

        uint256 calculatedStakingRewards = token.calculateStakingRewards(account, timestampAfterWarpTime);

        uint256 elapsedTime = timestampAfterWarpTime - initialTimestamp;

        uint256 lpTotalSupply = lpToken.totalSupply();
        uint256 tokenQuantity = (lpAmount * reserve0) / lpTotalSupply;

        uint256 cubicMultiplier = token.calculateCubicMultiplier(2e6, 365 days, elapsedTime);

        uint256 expectedStakingRewards = (tokenQuantity * INTEREST_RATE * elapsedTime * cubicMultiplier) /
            (10_000 * 365 days * 1e6);

        assertApproxEqAbs(
            calculatedStakingRewards,
            expectedStakingRewards,
            1e12,
            "Staking rewards calculation mismatch"
        );
    }
}
