// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.23;

import { Script } from "forge-std/Script.sol";
import { CompotaToken } from "../src/CompotaToken.sol";

contract CompotaTokenScript is Script {
    CompotaToken internal token;

    /// @dev Included to enable compilation of the script without a $MNEMONIC environment variable.
    string internal constant TEST_MNEMONIC = "test test test test test test test test test test test junk";
    /// @dev The default yearly rate of interest in basis points (bps).
    uint16 internal constant YEARLY_RATE_DEFAULT = 1e3;
    /// @dev The address of the transaction broadcaster.
    address internal broadcaster;
    /// @dev Used to derive the broadcaster's address if $ETH_FROM is not defined.
    string internal mnemonic;
    /// @dev Yearly rate
    uint256 internal yearlyRate;

    constructor() {
        mnemonic = vm.envOr({ name: "MNEMONIC", defaultValue: TEST_MNEMONIC });
        (broadcaster, ) = deriveRememberKey({ mnemonic: mnemonic, index: 0 });
    }

    function run() public {
        vm.startBroadcast(broadcaster);
        token = new CompotaToken(YEARLY_RATE_DEFAULT, 1 days, 1_000_000_000e6);
        vm.stopBroadcast();
    }
}
