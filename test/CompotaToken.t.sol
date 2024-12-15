// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.23;

import { Test } from "forge-std/Test.sol";
import { CompotaToken } from "../src/CompotaToken.sol";
import { IERC20Extended } from "@mzero-labs/interfaces/IERC20Extended.sol";
import { ICompotaToken } from "../src/intefaces/ICompotaToken.sol";

contract CompotaTokenTest is Test {
    CompotaToken token;
    address owner = address(1);
    address alice = address(2);
    address bob = address(3);
    address minterEOA = address(4);
    address minterContract;

    uint256 constant SCALE_FACTOR = 10_000;
    uint256 constant INITIAL_SUPPLY = 1000 * 10e6;
    uint256 constant BURN_AMOUNT = 400 * 10e6;
    uint256 constant TRANSFER_AMOUNT = 300 * 10e6;
    uint256 constant INSUFFICIENT_AMOUNT = 0;
    uint16 constant INTEREST_RATE = 1000; // 10% APY in BPS

    function setUp() external {
        vm.prank(owner);
        token = new CompotaToken(INTEREST_RATE, 1 days, 1_000_000_000e6);
        minterContract = address(new MinterContract(address(token)));
    }

    function testInitialization() external view {
        assertEq(token.owner(), owner);
        assertEq(token.name(), "Compota Token");
        assertEq(token.symbol(), "COMPOTA");
        assertEq(token.yearlyRate(), 1e3);
        assertEq(token.cooldownPeriod(), 1 days);
    }

    function testMintingByOwner() external {
        _mint(owner, alice, INITIAL_SUPPLY);
        assertEq(token.balanceOf(alice), INITIAL_SUPPLY);
    }

    function testMintingFailsByNonOwner() external {
        // Alice tries to mint tokens
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICompotaToken.Unauthorized.selector));
        token.mint(alice, INITIAL_SUPPLY);
    }

    function testMintingByNewOwnerAfterTransfer() external {
        vm.prank(owner);
        // Transfer ownership to alice
        token.transferOwnership(alice);

        // owner should not be able to mint tokens anymore
        vm.expectRevert(abi.encodeWithSelector(ICompotaToken.Unauthorized.selector));
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

        vm.warp(block.timestamp + 365 days);

        uint interest = (INITIAL_SUPPLY * INTEREST_RATE * 365 days) / (SCALE_FACTOR * 365 days);
        uint256 expectedFinalBalance = INITIAL_SUPPLY + interest;
        assertEq(token.balanceOf(alice), expectedFinalBalance);
    }

    function testInterestAccrualWithMultipleMints() external {
        _mint(owner, alice, INITIAL_SUPPLY);
        uint256 balanceRaw = INITIAL_SUPPLY;

        vm.warp(block.timestamp + 180 days);

        // Update rewards to calculate interest for the first 180 days
        uint256 firstPeriodInterest = (balanceRaw * INTEREST_RATE * 180 days) / (SCALE_FACTOR * 365 days);
        uint256 expectedBalance = balanceRaw + firstPeriodInterest;

        _mint(owner, alice, INITIAL_SUPPLY);
        balanceRaw += INITIAL_SUPPLY + firstPeriodInterest;
        expectedBalance += INITIAL_SUPPLY;

        vm.warp(block.timestamp + 185 days);

        // Update rewards to calculate interest for the next 185 days with updated balance
        uint256 secondPeriodInterest = (balanceRaw * INTEREST_RATE * 185 days) / (SCALE_FACTOR * 365 days);
        expectedBalance += secondPeriodInterest;

        assertEq(token.balanceOf(alice), expectedBalance);
    }

    function testInterestAccrualWithRateChange() external {
        uint16 initialRate = 1000; // 10% APY
        uint16 newRate = 500; // 5% APY

        vm.prank(owner);
        token.setYearlyRate(initialRate);

        _mint(owner, alice, INITIAL_SUPPLY);
        uint256 balanceRaw = INITIAL_SUPPLY;
        vm.warp(block.timestamp + 180 days);

        vm.prank(alice);
        token.claimRewards();
        uint256 firstPeriodInterest = (balanceRaw * initialRate * 180 days) / (SCALE_FACTOR * 365 days);
        balanceRaw += firstPeriodInterest;

        vm.prank(owner);
        token.setYearlyRate(newRate);

        uint256 tokensToMint = 500 * 10e6;
        _mint(owner, alice, tokensToMint);
        balanceRaw += tokensToMint;

        vm.warp(block.timestamp + 30 days);

        // Claim rewards again after the next 30 days with the new rate
        vm.prank(alice);
        token.claimRewards();
        uint256 secondPeriodInterest = (balanceRaw * newRate * 30 days) / (SCALE_FACTOR * 365 days);
        balanceRaw += secondPeriodInterest;

        uint256 expectedFinalBalance = balanceRaw;
        assertEq(token.balanceOf(alice), expectedFinalBalance);
    }

    function testInterestAccrualWithoutBalanceChange() external {
        uint256 tokensToMint = 10e3;
        _mint(owner, alice, tokensToMint);
        uint256 balanceRaw = tokensToMint;
        vm.warp(block.timestamp + 10 days);

        uint256 firstPeriodInterest = (balanceRaw * INTEREST_RATE * 10 days) / (SCALE_FACTOR * 365 days);
        assertEq(token.balanceOf(alice), balanceRaw + firstPeriodInterest);

        vm.warp(block.timestamp + 18 days);

        uint256 secondPeriodInterest = (balanceRaw * INTEREST_RATE * 18 days) / (SCALE_FACTOR * 365 days);
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
        CompotaToken newToken = new CompotaToken(500, 1 days, 1_000_000_000e6);
        assertEq(newToken.yearlyRate(), 500);
    }

    function testConstructorRevertsOnInvalidYearlyRate() public {
        vm.expectRevert(abi.encodeWithSelector(ICompotaToken.InvalidYearlyRate.selector, 0));
        new CompotaToken(0, 1 days, 1_000_000_000e6);

        vm.expectRevert(abi.encodeWithSelector(ICompotaToken.InvalidYearlyRate.selector, 50000));
        new CompotaToken(50000, 1 days, 1_000_000_000e6);
    }

    function testInterestAccumulationAfterTransfer() external {
        _mint(owner, alice, INITIAL_SUPPLY);
        uint256 aliceBalanceRaw = INITIAL_SUPPLY;
        vm.warp(block.timestamp + 180 days);

        uint256 firstPeriodInterestAlice = (aliceBalanceRaw * INTEREST_RATE * 180 days) / (SCALE_FACTOR * 365 days);

        _transfer(alice, bob, TRANSFER_AMOUNT);
        aliceBalanceRaw -= TRANSFER_AMOUNT;
        uint256 bobBalanceRaw = TRANSFER_AMOUNT;

        vm.prank(alice);
        token.claimRewards();

        uint256 aliceTotalBalance = aliceBalanceRaw + firstPeriodInterestAlice;

        vm.warp(block.timestamp + 185 days);

        vm.prank(alice);
        token.claimRewards();
        vm.prank(bob);
        token.claimRewards();

        uint256 secondPeriodInterestAlice = (aliceTotalBalance * INTEREST_RATE * 185 days) / (SCALE_FACTOR * 365 days);
        uint256 secondPeriodInterestBob = (bobBalanceRaw * INTEREST_RATE * 185 days) / (SCALE_FACTOR * 365 days);

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

        uint256 expectedRewards = (totalSupply * INTEREST_RATE * 180 days) / (SCALE_FACTOR * 365 days);

        assertEq(token.totalSupply(), totalSupply + expectedRewards);
    }

    function testClaimRewardsCooldownNotCompleted() public {
        vm.prank(owner);
        token.mint(alice, 1000 * 10e6);

        vm.prank(alice);

        vm.expectRevert(abi.encodeWithSelector(ICompotaToken.CooldownNotCompleted.selector, 1 days));
        token.claimRewards();
    }

    function testClaimRewardsWithCooldownPeriod() public {
        _mint(owner, alice, INITIAL_SUPPLY);

        vm.warp(block.timestamp + 10 days);

        vm.prank(alice);
        token.claimRewards();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICompotaToken.CooldownNotCompleted.selector, 1 days));
        token.claimRewards();

        vm.warp(block.timestamp + 1 days);

        vm.prank(alice);
        token.claimRewards();
    }

    function testDynamicCooldownPeriodChange() public {
        _mint(owner, alice, INITIAL_SUPPLY);

        vm.prank(owner);
        token.setCooldownPeriod(12 hours);
        assertEq(token.cooldownPeriod(), 12 hours);

        vm.warp(block.timestamp + 15 days);

        vm.prank(alice);
        token.claimRewards();

        vm.warp(block.timestamp + 13 hours);

        vm.prank(alice);
        token.claimRewards();
    }

    function testClaimFailsAfterCooldownIncrease() public {
        _mint(owner, alice, INITIAL_SUPPLY);

        vm.warp(block.timestamp + 10 days);

        vm.prank(alice);
        token.claimRewards();

        vm.prank(owner);
        token.setCooldownPeriod(3 days);
        assertEq(token.cooldownPeriod(), 3 days);

        vm.warp(block.timestamp + 2 days);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICompotaToken.CooldownNotCompleted.selector, 1 days));
        token.claimRewards();
    }

    function testCooldownDoesNotAffectMintingOrBurning() public {
        _mint(owner, alice, INITIAL_SUPPLY);

        _mint(owner, alice, 500 * 10e6);
        assertEq(token.balanceOf(alice), INITIAL_SUPPLY + (500 * 10e6));

        _burn(alice, 200 * 10e6);
        assertEq(token.balanceOf(alice), (INITIAL_SUPPLY + (500 * 10e6)) - (200 * 10e6));
    }

    function testCooldownDoesNotAffectTransfer() public {
        _mint(owner, alice, INITIAL_SUPPLY);

        uint256 aliceBalanceRaw = INITIAL_SUPPLY;
        vm.warp(block.timestamp + 10 days);

        uint256 interest = (aliceBalanceRaw * INTEREST_RATE * 10 days) / (SCALE_FACTOR * 365 days);

        _transfer(alice, bob, 200 * 10e6);
        assertEq(token.balanceOf(alice), INITIAL_SUPPLY + interest - 200 * 10e6);
        assertEq(token.balanceOf(bob), 200 * 10e6);
    }

    function testSetCooldownPeriodByNonOwnerFails() public {
        vm.prank(alice);
        vm.expectRevert("UNAUTHORIZED");
        token.setCooldownPeriod(12 hours);
    }

    function testSetCooldownPeriodToZero() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ICompotaToken.InvalidCooldownPeriod.selector, 0));
        token.setCooldownPeriod(0);
    }

    function testMinterCanMintTokens() public {
        vm.prank(owner);
        token.transferMinter(minterEOA);

        vm.prank(minterEOA);
        token.mint(alice, INITIAL_SUPPLY);

        assertEq(token.balanceOf(alice), INITIAL_SUPPLY);
    }

    function testNonMinterCannotMintTokens() public {
        vm.prank(owner);
        token.transferMinter(minterEOA);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ICompotaToken.Unauthorized.selector));
        token.mint(alice, INITIAL_SUPPLY);
    }

    function testOnlyOwnerCanChangeMinter() public {
        vm.prank(bob);
        vm.expectRevert("UNAUTHORIZED");
        token.transferMinter(minterEOA);

        vm.prank(owner);
        token.transferMinter(minterEOA);

        assertEq(token.minter(), minterEOA);
    }

    function testMinterContractCanMintTokens() public {
        vm.prank(owner);
        token.transferMinter(minterContract);

        vm.prank(minterContract);
        MinterContract(minterContract).mintTokens(alice, INITIAL_SUPPLY);

        assertEq(token.balanceOf(alice), INITIAL_SUPPLY);
    }

    function testMinterTransferEmitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit ICompotaToken.MinterTransferred(address(0), minterEOA);
        token.transferMinter(minterEOA);
    }

    function testMintCannotExceedMaxTotalSupply() public {
        uint224 maxSupply = 1_000_000 * 10e6;
        vm.prank(owner);
        token = new CompotaToken(INTEREST_RATE, 1 days, maxSupply);

        uint256 mintable = 900_000 * 10e6;
        _mint(owner, alice, mintable);

        uint256 remaining = maxSupply - mintable;
        _mint(owner, bob, remaining);

        _mint(owner, bob, 1);
        assertEq(token.totalSupply(), maxSupply);

        vm.warp(block.timestamp + 100 days);
        assertEq(token.totalSupply(), maxSupply);
    }

    function testMintPartialWhenNearMaxTotalSupply() public {
        uint224 maxSupply = 1_000_000 * 10e6;
        vm.prank(owner);
        token = new CompotaToken(INTEREST_RATE, 1 days, maxSupply);

        uint256 mintable = 999_999 * 10e6;
        _mint(owner, alice, mintable);

        uint256 remaining = maxSupply - mintable;

        vm.prank(owner);
        token.mint(bob, 2 * 10e6);

        assertEq(token.balanceOf(bob), remaining);
        assertEq(token.totalSupply(), maxSupply);
    }

    function testInterestAccrualRespectsMaxTotalSupply() external {
        uint224 maxSupply = 600 * 10e6;
        vm.prank(owner);
        token = new CompotaToken(INTEREST_RATE, 1 days, maxSupply);

        uint256 initialMint = 300 * 10e6;
        _mint(owner, alice, initialMint);

        uint256 balanceRaw = initialMint;

        uint256 timeElapsed = 180 days;
        vm.warp(block.timestamp + timeElapsed);

        uint256 firstPeriodInterest = (balanceRaw * INTEREST_RATE * timeElapsed) / (SCALE_FACTOR * 365 days);
        uint256 expectedSupply = balanceRaw + firstPeriodInterest;

        uint256 totalSupplyAfterInterest = token.totalSupply();
        assertEq(totalSupplyAfterInterest, expectedSupply, "Total supply after interest mismatch");
        assertTrue(totalSupplyAfterInterest <= maxSupply, "Total supply exceeded maxTotalSupply");

        uint256 additionalMint = 400 * 10e6;
        uint256 remainingSupply = maxSupply - token.totalSupply();
        uint256 adjustedMint = additionalMint > remainingSupply ? remainingSupply : additionalMint;
        _mint(owner, alice, adjustedMint);

        expectedSupply += adjustedMint;
        assertEq(token.totalSupply(), expectedSupply, "Total supply should equal maxTotalSupply");

        timeElapsed = 185 days;
        vm.warp(block.timestamp + timeElapsed);

        assertEq(token.totalSupply(), maxSupply, "Total supply should not exceed maxTotalSupply");
        assertEq(token.balanceOf(alice), maxSupply, "Alice's balance should match maxTotalSupply");
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

/**
 * @dev Helper contract to simulate a minter contract.
 */
contract MinterContract {
    CompotaToken public token;

    constructor(address tokenAddress) {
        token = CompotaToken(tokenAddress);
    }

    function mintTokens(address to, uint256 amount) external {
        token.mint(to, amount);
    }
}
