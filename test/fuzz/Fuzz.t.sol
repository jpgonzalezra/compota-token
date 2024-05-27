// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.23;

import { Test } from "forge-std/Test.sol";
import { InterestBearingToken } from "../../src/InterestBearingToken.sol";

contract FuzzTests is Test {
    InterestBearingToken token;
    address owner = address(0x1);
    address alice = address(0x2);
    address bob = address(0x3);

    uint16 constant INTEREST_RATE = 1000; // 10% APY
    uint256 constant INITIAL_MINT = 1000 * 10 ** 6;

    function setUp() public {
        vm.startPrank(owner);
        token = new InterestBearingToken(INTEREST_RATE);
        vm.stopPrank();
    }

    function testFuzzMint(address to, uint256 amount) public {
        vm.assume(to != address(0));
        vm.assume(amount > 0);
        vm.assume(amount <= 1e24);

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
}
