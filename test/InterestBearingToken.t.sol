// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { InterestBearingToken } from "../src/InterestBearingToken.sol";

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

contract InterestBearingTokenTest is Test {
    InterestBearingToken token;
    address owner = address(1);
    address alice = address(2);
    address bob = address(3);
    address charly = address(4);

    uint256 constant INITIAL_SUPPLY = 1000 * 10e6;
    uint256 constant BURN_AMOUNT = 400 * 10e6;
    uint256 constant TRANSFER_AMOUNT = 300 * 10e6;
    uint256 constant INSUFFICIENT_AMOUNT = 0;

    error InvalidRecipient(address recipient_);
    error InsufficientAmount(uint256 amount_);

    function setUp() external {
        vm.prank(owner);
        token = new InterestBearingToken(1e3); // 10% APY in BPS
    }

    function testInitialization() external view {
        assertEq(token.owner(), owner);
        assertEq(token.name(), "IBToken");
        assertEq(token.symbol(), "IB");
        assertEq(token.interestRate(), 1e3);
    }

    /* ============ Mint tests ============ */

    function testMintingByOwner() external {
        _mint(owner, alice, INITIAL_SUPPLY);
        assertEq(token.balanceOf(alice), INITIAL_SUPPLY);
    }

    function testMintingByNonOwner() external {
        // Alice tries to mint tokens
        vm.prank(alice);
        vm.expectRevert("UNAUTHORIZED");
        token.mint(alice, INITIAL_SUPPLY);
    }

    function testMintingByOwnerAfterOwnershipTransfer() external {
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
        vm.expectRevert(abi.encodeWithSelector(InvalidRecipient.selector, address(0)));
        token.mint(address(0), INITIAL_SUPPLY);
    }

    function testMintingInsufficientAmount() external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(InsufficientAmount.selector, INSUFFICIENT_AMOUNT));
        token.mint(alice, INSUFFICIENT_AMOUNT);
    }

    /* ============ Burn tests ============ */

    function testBurningCorrectly() public {
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
        vm.expectRevert(abi.encodeWithSelector(InsufficientAmount.selector, valueToBurn));
        token.burn(valueToBurn);
    }

    function testBurningInsufficientAmount() public {
        _mint(owner, alice, INITIAL_SUPPLY);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InsufficientAmount.selector, INSUFFICIENT_AMOUNT));
        token.burn(INSUFFICIENT_AMOUNT);
    }

    function testBurningAllTokens() public {
        _mint(owner, alice, INITIAL_SUPPLY);
        _burn(alice, INITIAL_SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function testBurningAfterTransfer() public {
        _mint(owner, alice, INITIAL_SUPPLY);
        _transfer(alice, bob, TRANSFER_AMOUNT);
        _burn(alice, BURN_AMOUNT);
        assertEq(token.balanceOf(alice), INITIAL_SUPPLY - TRANSFER_AMOUNT - BURN_AMOUNT);
        assertEq(token.balanceOf(bob), TRANSFER_AMOUNT);
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
