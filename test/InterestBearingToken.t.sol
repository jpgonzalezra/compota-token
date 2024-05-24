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

    function testMintingByOwner() external {
        vm.prank(owner);
        token.mint(alice, 1000 * 10e6); // Mint 1000 tokens to alice
        assertEq(token.balanceOf(alice), 1000 * 10e6);
    }

    function testMintingByNonOwner() external {
        // Alice tries to mint tokens
        vm.prank(alice);
        vm.expectRevert("UNAUTHORIZED");
        token.mint(alice, 1000 * 10e6);
    }

    function testMintingByOwnerAfterOwnershipTransfer() external {
        vm.prank(owner);
        // Transfer ownership to alice
        token.transferOwnership(alice);

        // owner should not be able to mint tokens anymore
        vm.expectRevert("UNAUTHORIZED");
        token.mint(bob, 1000 * 10e6);

        // alice should be able to mint tokens now
        vm.prank(alice);
        token.mint(bob, 1000 * 10e6);
        assertEq(token.balanceOf(bob), 1000 * 10e6);
    }

    function testMintingInvalidRecipient() external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(InvalidRecipient.selector, address(0)));
        token.mint(address(0), 1000 * 10e6);
    }

    function testMintingInsufficientAmount() external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(InsufficientAmount.selector, 0));
        token.mint(alice, 0);
    }
}
