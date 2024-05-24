// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

contract FooTest is Test {
    function setUp() public {}

    /// @dev Simple test. Run Forge with `-vvvv` to see stack traces.
    function test() external view {}
}
