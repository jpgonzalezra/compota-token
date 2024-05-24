// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.26;

import { ERC20 } from "solmate/tokens/ERC20.sol";
import { Owned } from "solmate/auth/Owned.sol";

contract InterestBearingToken is ERC20, Owned {
    uint256 public interestRate; // interest rate in BPS

    constructor(uint256 interestRate_) ERC20("IBToken", "IB", 6) Owned(msg.sender) {
        interestRate = interestRate_;
    }
}
