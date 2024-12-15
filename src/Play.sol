// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.23;

import { CompotaToken } from "./CompotaToken.sol";

contract Play is CompotaToken {
    constructor(
        uint16 yearlyRate_,
        uint32 cooldownPeriod_
    ) CompotaToken(yearlyRate_, cooldownPeriod_, 1_000_000_000e6) {
        _mint(msg.sender, 890_000_000e6);
    }
}
