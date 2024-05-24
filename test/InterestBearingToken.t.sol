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

    function setUp() public {
        vm.prank(owner);
        token = new InterestBearingToken(1e3); // 10% APY in BPS
    }

    function testInitialization() public view {
        assertEq(token.name(), "IBToken");
        assertEq(token.symbol(), "IB");
        assertEq(token.interestRate(), 1e3);
    }
}
