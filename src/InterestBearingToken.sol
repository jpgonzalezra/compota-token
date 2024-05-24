// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.26;

import { ERC20 } from "solmate/tokens/ERC20.sol";
import { Owned } from "solmate/auth/Owned.sol";

contract InterestBearingToken is ERC20, Owned {
    /* ============ Structs ============ */
    // nothing for now

    /* ============ Errors ============ */
    error InvalidRecipient(address recipient_);
    error InsufficientAmount(uint256 amount_);

    /* ============ Variables ============ */
    uint256 public interestRate; // interest rate in BPS

    /* ============ Modifiers ============ */
    // nothing for now

    /* ============ Constructor ============ */
    constructor(uint256 interestRate_) ERC20("IBToken", "IB", 6) Owned(msg.sender) {
        interestRate = interestRate_;
    }

    /* ============ Interactive Functions ============ */
    function mint(address to_, uint256 amount_) external onlyOwner {
        _revertIfInvalidRecipient(to_);
        _revertIfInsufficientAmount(amount_);
        // _updateInterest(to_)
        _mint(to_, amount_);
    }

    function burn(uint256 amount_) external {
        _revertIfInsufficientAmount(amount_);
        if (this.balanceOf(msg.sender) < amount_) revert InsufficientAmount(amount_);
        address caller = msg.sender;
        // _updateInterest(caller)
        _burn(caller, amount_);
    }

    /* ============ Internal Interactive Functions ============ */

    function _updateInterest(address to_) internal {
        // nothing for now
    }

    /**
     * @dev   Reverts if the amount of a `mint` or `burn` is equal to 0.
     * @param amount_ Amount to check.
     */
    function _revertIfInsufficientAmount(uint256 amount_) internal pure {
        if (amount_ == 0) revert InsufficientAmount(amount_);
    }

    /**
     * @dev   Reverts if the recipient of a `mint` or `transfer` is address(0).
     * @param recipient_ Address of the recipient to check.
     */
    function _revertIfInvalidRecipient(address recipient_) internal pure {
        if (recipient_ == address(0)) revert InvalidRecipient(recipient_);
    }
}
