// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.23;

import { Script } from "forge-std/Script.sol";
import { InterestBearingToken } from "../src/InterestBearingToken.sol";

contract InterestBearingTokenScript is Script {
    InterestBearingToken internal token;

    function run() public {
        vm.startBroadcast();
        token = new InterestBearingToken(1e3);
        vm.stopBroadcast();
    }
}
