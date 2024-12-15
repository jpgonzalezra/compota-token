// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.23;

import { Test } from "forge-std/Test.sol";
import { CompotaToken } from "../../src/CompotaToken.sol";
import { ICompotaToken } from "../../src/intefaces/ICompotaToken.sol";

contract FuzzTests is Test {
    CompotaToken token;
    address owner = address(this);
    address alice = address(0x2);
    address bob = address(0x3);

    uint16 constant INTEREST_RATE = 1000; // 10% APY
    uint256 constant INITIAL_MINT = 1000 * 10 ** 6;
    uint256 constant MAX_SUPPLY = 1_000_000_000e6;

    function setUp() public {
        vm.startPrank(owner);
        token = new CompotaToken(INTEREST_RATE, 1 days, 1_000_000_000e6);
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
            vm.expectRevert(abi.encodeWithSelector(ICompotaToken.InvalidYearlyRate.selector, newRate));
            token.setYearlyRate(newRate);
        } else {
            uint16 oldRate = token.yearlyRate();

            vm.expectEmit(true, true, true, true);
            emit ICompotaToken.YearlyRateUpdated(oldRate, newRate);

            token.setYearlyRate(newRate);

            assertEq(token.yearlyRate(), newRate);
        }
    }
}
