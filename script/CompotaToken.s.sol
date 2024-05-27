// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.23;

import { Script } from "forge-std/Script.sol";
import { CompotaToken } from "../src/CompotaToken.sol";

contract CompotaTokenScript is Script {
    CompotaToken internal token;

    function run() public {
        vm.startBroadcast();
        token = new CompotaToken(1e3);
        vm.stopBroadcast();
    }
}
