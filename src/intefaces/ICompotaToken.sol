// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.23;

import { IERC20 } from "@mzero-labs/interfaces/IERC20.sol";
import { IERC20Extended } from "@mzero-labs/interfaces/IERC20Extended.sol";

interface ICompotaToken is IERC20Extended {
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

    /**
     * @notice Emitted when the cooldown period is updated.
     * @param oldCooldownPeriod The cooldown period before the update, in seconds.
     * @param newCooldownPeriod The cooldown period after the update, in seconds.
     */
    event CooldownPeriodUpdated(uint32 oldCooldownPeriod, uint32 newCooldownPeriod);

    /**
     * @notice Emitted when the minter role is transferred to a new address.
     * @param oldMinter The address of the previous minter.
     * @param newMinter The address of the new minter.
     */
    event MinterTransferred(address indexed oldMinter, address indexed newMinter);
    /* ============ Custom Errors ============ */

    /// @notice Error thrown when the yearly rate is invalid.
    error InvalidYearlyRate(uint16 rate);

    /// @notice Error thrown when the cooldown is invalid.
    error InvalidCooldownPeriod(uint32 cooldownPeriod);

    /// @notice Error thrown when the balance is insufficient for a specific operation.
    error InsufficientBalance(uint256 amount);

    /// @notice Emitted when a passed value is greater than the maximum value of uint224.
    error InvalidUInt224();

    /// @notice Emitted when a user attempts to claim rewards before the cooldown period has elapsed.
    error CooldownNotCompleted(uint32 remainingCooldown);

    /// @notice Emitted when a function is called by an address that is not authorized to perform the action.
    error Unauthorized();

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
