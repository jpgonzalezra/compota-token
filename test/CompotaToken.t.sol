// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.23;

import { Test, console } from "forge-std/Test.sol";
import { CompotaToken } from "../src/CompotaToken.sol";
import { IERC20Extended } from "@mzero-labs/interfaces/IERC20Extended.sol";
import { ICompotaToken } from "../src/intefaces/ICompotaToken.sol";

contract CompotaTokenTest is Test {
    CompotaToken token;
    address owner = address(1);
    address alice = address(2);
    address bob = address(3);

    uint256 constant INITIAL_SUPPLY = 1000 * 10e6;
    uint256 constant BURN_AMOUNT = 400 * 10e6;
    uint256 constant TRANSFER_AMOUNT = 300 * 10e6;
    uint256 constant INSUFFICIENT_AMOUNT = 0;
    uint16 constant INTEREST_RATE = 1000; // 10% APY in BPS

    function setUp() external {
        vm.prank(owner);
        token = new CompotaToken(INTEREST_RATE);
    }

    function testInitialization() external view {
        assertEq(token.owner(), owner);
        assertEq(token.name(), "Compota Token");
        assertEq(token.symbol(), "COMPOTA");
        assertEq(token.yearlyRate(), 1e3);
    }

    function testMintingByOwner() external {
        _mint(owner, alice, INITIAL_SUPPLY);
        assertEq(token.balanceOf(alice), INITIAL_SUPPLY);
    }

    function testMintingFailsByNonOwner() external {
        // Alice tries to mint tokens
        vm.prank(alice);
        vm.expectRevert("UNAUTHORIZED");
        token.mint(alice, INITIAL_SUPPLY);
    }

    function testMintingByNewOwnerAfterTransfer() external {
        vm.prank(owner);
        // Transfer ownership to alice
        token.transferOwnership(alice);

        // owner should not be able to mint tokens anymore
        vm.expectRevert("UNAUTHORIZED");
        token.mint(bob, INITIAL_SUPPLY);

        // alice should be able to mint tokens now
        _mint(alice, bob, INITIAL_SUPPLY);
        assertEq(token.balanceOf(bob), INITIAL_SUPPLY);
    }

    function testMintingInvalidRecipient() external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IERC20Extended.InvalidRecipient.selector, address(0)));
        token.mint(address(0), INITIAL_SUPPLY);
    }

    function testMintingInsufficientAmount() external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IERC20Extended.InsufficientAmount.selector, INSUFFICIENT_AMOUNT));
        token.mint(alice, INSUFFICIENT_AMOUNT);
    }

    function testBurningTokensCorrectly() public {
        _mint(owner, alice, INITIAL_SUPPLY);
        _burn(alice, BURN_AMOUNT);
        assertEq(token.balanceOf(alice), INITIAL_SUPPLY - BURN_AMOUNT);
        _burn(alice, BURN_AMOUNT / 2);
        assertEq(token.balanceOf(alice), INITIAL_SUPPLY - (BURN_AMOUNT + (BURN_AMOUNT / 2)));
    }

    function testBurningMoreThanBalance() public {
        _mint(owner, alice, INITIAL_SUPPLY);
        uint256 valueToBurn = INITIAL_SUPPLY + BURN_AMOUNT;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICompotaToken.InsufficientBalance.selector, valueToBurn));
        token.burn(valueToBurn);
    }

    function testBurningFailsWithInsufficientAmount() public {
        _mint(owner, alice, INITIAL_SUPPLY);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Extended.InsufficientAmount.selector, INSUFFICIENT_AMOUNT));
        token.burn(INSUFFICIENT_AMOUNT);
    }

    function testBurningAllTokens() public {
        _mint(owner, alice, INITIAL_SUPPLY);
        _burn(alice, INITIAL_SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function testBurningTokensAfterTransfer() public {
        _mint(owner, alice, INITIAL_SUPPLY);
        _transfer(alice, bob, TRANSFER_AMOUNT);
        _burn(alice, BURN_AMOUNT);
        assertEq(token.balanceOf(alice), INITIAL_SUPPLY - TRANSFER_AMOUNT - BURN_AMOUNT);
        assertEq(token.balanceOf(bob), TRANSFER_AMOUNT);
    }

    function testInterestAccrualAfterOneYear() external {
        vm.prank(owner);
        vm.expectEmit();
        emit ICompotaToken.StartedEarningRewards(alice);
        token.mint(alice, INITIAL_SUPPLY);

        // Trigger interest calculation
        vm.warp(block.timestamp + 365 days);

        uint interest = (INITIAL_SUPPLY * INTEREST_RATE * 365 days) / (10_000 * 365 days);
        uint256 expectedFinalBalance = INITIAL_SUPPLY + interest;
        assertEq(token.balanceOf(alice), expectedFinalBalance);
    }

    function testInterestAccrualWithMultipleMints() external {
        // Mint initial supply to Alice
        _mint(owner, alice, INITIAL_SUPPLY);
        uint256 balanceRaw = INITIAL_SUPPLY;

        vm.warp(block.timestamp + 180 days);

        // Update rewards to calculate interest for the first 180 days
        uint256 firstPeriodInterest = (balanceRaw * INTEREST_RATE * 180 days) / (10_000 * 365 days);
        uint256 expectedBalance = balanceRaw + firstPeriodInterest;

        _mint(owner, alice, INITIAL_SUPPLY);
        balanceRaw += INITIAL_SUPPLY + firstPeriodInterest; // Compound
        expectedBalance += INITIAL_SUPPLY;

        // Warp time by another 185 days (total 365 days from first mint)
        vm.warp(block.timestamp + 185 days);

        // Update rewards to calculate interest for the next 185 days with updated balance
        uint256 secondPeriodInterest = (balanceRaw * INTEREST_RATE * 185 days) / (10_000 * 365 days);
        expectedBalance += secondPeriodInterest;

        // Check final balance
        assertEq(token.balanceOf(alice), expectedBalance);
    }

    function testInterestAccrualWithRateChange() external {
        uint16 initialRate = 1000; // 10% APY
        uint16 newRate = 500; // 5% APY

        vm.prank(owner);
        token.setYearlyRate(initialRate);

        // First mint and time warp
        _mint(owner, alice, INITIAL_SUPPLY);
        uint256 balanceRaw = INITIAL_SUPPLY;
        vm.warp(block.timestamp + 180 days);

        // Claim rewards and update balance after the first 180 days with the initial rate
        vm.prank(alice);
        token.claimRewards();
        uint256 firstPeriodInterest = (balanceRaw * initialRate * 180 days) / (10_000 * 365 days);
        balanceRaw += firstPeriodInterest;

        // Change the interest rate
        vm.prank(owner);
        token.setYearlyRate(newRate);

        // Second mint and balance update
        uint256 tokensToMint = 500 * 10e6;
        _mint(owner, alice, tokensToMint);
        balanceRaw += tokensToMint;

        vm.warp(block.timestamp + 30 days);

        // Claim rewards again after the next 30 days with the new rate
        vm.prank(alice);
        token.claimRewards();
        uint256 secondPeriodInterest = (balanceRaw * newRate * 30 days) / (10_000 * 365 days);
        balanceRaw += secondPeriodInterest;

        // Expected final balance should include all interests claimed
        uint256 expectedFinalBalance = balanceRaw;
        assertEq(token.balanceOf(alice), expectedFinalBalance);
    }

    function testInterestAccrualWithoutBalanceChange() external {
        uint256 tokensToMint = 10e3;
        _mint(owner, alice, tokensToMint);
        uint256 balanceRaw = tokensToMint;
        vm.warp(block.timestamp + 10 days);

        // Calculate interest for the first 10 days
        uint256 firstPeriodInterest = (balanceRaw * INTEREST_RATE * 10 days) / (10_000 * 365 days);
        assertEq(token.balanceOf(alice), balanceRaw + firstPeriodInterest);

        // Warp time forward without changing the balance
        vm.warp(block.timestamp + 18 days);

        // Calculate interest for the next 18 days with the same balance
        uint256 secondPeriodInterest = (balanceRaw * INTEREST_RATE * 18 days) / (10_000 * 365 days);
        uint256 expectedFinalBalance = balanceRaw + firstPeriodInterest + secondPeriodInterest;
        assertEq(token.balanceOf(alice), expectedFinalBalance);
    }

    function testSetYearlyRate() public {
        // Only the owner should be able to set the yearly rate within the valid range
        vm.prank(owner);
        token.setYearlyRate(500);
        assertEq(token.yearlyRate(), 500);

        // Expect revert if non-owner tries to set the yearly rate
        vm.prank(alice);
        vm.expectRevert("UNAUTHORIZED");
        token.setYearlyRate(100);

        vm.prank(owner);
        // Test with invalid rate below minimum
        vm.expectRevert(abi.encodeWithSelector(ICompotaToken.InvalidYearlyRate.selector, 99));
        token.setYearlyRate(99);

        vm.prank(owner);
        // Test with invalid rate above maximum
        vm.expectRevert(abi.encodeWithSelector(ICompotaToken.InvalidYearlyRate.selector, 40001));
        token.setYearlyRate(40001);
    }

    function testConstructorInitializesYearlyRate() public {
        CompotaToken newToken = new CompotaToken(500);
        assertEq(newToken.yearlyRate(), 500);
    }

    function testConstructorRevertsOnInvalidYearlyRate() public {
        vm.expectRevert(abi.encodeWithSelector(ICompotaToken.InvalidYearlyRate.selector, 0));
        new CompotaToken(0);

        vm.expectRevert(abi.encodeWithSelector(ICompotaToken.InvalidYearlyRate.selector, 50000));
        new CompotaToken(50000);
    }

    function testInterestAccumulationAfterTransfer() external {
        _mint(owner, alice, INITIAL_SUPPLY);
        uint256 aliceBalanceRaw = INITIAL_SUPPLY;
        vm.warp(block.timestamp + 180 days);

        // Calculate interest for the first 180 days
        uint256 firstPeriodInterestAlice = (aliceBalanceRaw * INTEREST_RATE * 180 days) / (10_000 * 365 days);

        // Transfer tokens from Alice to Bob
        _transfer(alice, bob, TRANSFER_AMOUNT);
        aliceBalanceRaw -= TRANSFER_AMOUNT;
        uint256 bobBalanceRaw = TRANSFER_AMOUNT;

        // Alice claims rewards after the first 180 days before the transfer
        vm.prank(alice);
        token.claimRewards();

        // Update Alice's balance to include the first period interest
        uint256 aliceTotalBalance = aliceBalanceRaw + firstPeriodInterestAlice;

        // Calculate interest for the next 185 days with updated balance
        vm.warp(block.timestamp + 185 days);

        // Update interests for Alice and Bob
        vm.prank(alice);
        token.claimRewards();
        vm.prank(bob);
        token.claimRewards();

        uint256 secondPeriodInterestAlice = (aliceTotalBalance * INTEREST_RATE * 185 days) / (10_000 * 365 days);
        uint256 secondPeriodInterestBob = (bobBalanceRaw * INTEREST_RATE * 185 days) / (10_000 * 365 days);

        uint256 expectedFinalBalanceAlice = aliceTotalBalance + secondPeriodInterestAlice;
        uint256 expectedFinalBalanceBob = bobBalanceRaw + secondPeriodInterestBob;

        assertEq(token.balanceOf(alice), expectedFinalBalanceAlice);
        assertEq(token.balanceOf(bob), expectedFinalBalanceBob);
    }

    function testTotalSupplyWithUnclaimedRewards() external {
        uint256 aliceInitialMint = 1000 * 10e6;
        uint256 bobInitialMint = aliceInitialMint * 2;

        _mint(owner, alice, aliceInitialMint);
        _mint(owner, bob, bobInitialMint);

        uint256 totalSupply = aliceInitialMint + bobInitialMint;
        assertEq(token.totalSupply(), totalSupply);

        vm.warp(block.timestamp + 180 days);

        // Calculate expected rewards for 180 days with the initial rate
        uint256 expectedRewards = (totalSupply * INTEREST_RATE * 180 days) / (10_000 * 365 days);

        // Verify total supply includes unclaimed rewards
        assertEq(token.totalSupply(), totalSupply + expectedRewards);
    }

    function testClaimRewardsWithNoRewards() public {
        vm.prank(owner);
        token.mint(alice, 1000 * 10e6);

        uint256 initialBalance = token.balanceOf(alice);

        vm.prank(alice);
        token.claimRewards();

        uint256 finalBalance = token.balanceOf(alice);

        assertEq(initialBalance, finalBalance);
    }

    /* ============ Helper functions ============ */

    function _mint(address minter, address to, uint256 amount) internal {
        vm.prank(minter);
        token.mint(to, amount);
    }

    function _burn(address burner, uint256 amount) internal {
        vm.prank(burner);
        token.burn(amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        vm.prank(from);
        token.transfer(to, amount);
    }
}
