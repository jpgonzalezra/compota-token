// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.23;

import { IERC20 } from "@mzero-labs/interfaces/IERC20.sol";
import { IERC20Extended } from "@mzero-labs/interfaces/IERC20Extended.sol";

interface IInterestBearingToken is IERC20Extended {
    /* ============ Events ============ */

    /**
     * @notice Emmited when the account starts earning token
     * @param  account The account that started earning.
     */
    event StartedEarningRewards(address indexed account);

    /**
     * @notice Emitted when the yearly rate is updated.
     * @param oldRate The previous yearly rate in basis points (BPS).
     * @param newRate The new yearly rate in basis points (BPS).
     */
    event YearlyRateUpdated(uint16 oldRate, uint16 newRate);

    /* ============ Custom Errors ============ */

    /// @notice Error thrown when the yearly rate is invalid.
    error InvalidYearlyRate(uint16 rate);

    /// @notice Error thrown when the balance is insufficient for a specific operation.
    error InsufficientBalance(uint256 amount);

    /* ============ Interactive Functions ============ */

    /**
     * @notice Sets the yearly rate of interest.
     * @dev Only the owner can call this function. The new rate must be between
     *      `MIN_YEARLY_RATE` (1% APY) and `MAX_YEARLY_RATE` (40% APY).
     * @param newRate_ The new interest rate in basis points (BPS).
     */
    function setYearlyRate(uint16 newRate_) external;

    /**
     * @notice Mints new tokens to a specified address.
     * @dev Only the owner can call this function.
     * @param to_ The address where the new tokens will be sent.
     * @param amount_ The number of tokens to mint.
     */
    function mint(address to_, uint256 amount_) external;

    /**
     * @notice Burns tokens from the sender account.
     * @param amount_ The number of tokens to burn.
     */
    function burn(uint256 amount_) external;

    /**
     * @notice Claims the accumulated rewards for the sender.
     * @dev It can only be called by the owner of the rewards.
     */
    function claimRewards() external;
}
