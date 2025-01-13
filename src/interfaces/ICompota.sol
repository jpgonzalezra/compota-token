// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { IERC20 } from "@mzero-labs/interfaces/IERC20.sol";
import { IERC20Extended } from "@mzero-labs/interfaces/IERC20Extended.sol";

interface ICompota is IERC20Extended {
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
     * @param oldRewardCooldownPeriod The reward cooldown period before the update, in seconds.
     * @param newRewardCooldownPeriod The reward cooldown period after the update, in seconds.
     */
    event RewardCooldownPeriodUpdated(uint32 oldRewardCooldownPeriod, uint32 newRewardCooldownPeriod);

    /**
     * @notice Emitted when the minter role is transferred to a new address.
     * @param oldMinter The address of the previous minter.
     * @param newMinter The address of the new minter.
     */
    event MinterTransferred(address indexed oldMinter, address indexed newMinter);

    /**
     * @notice Emitted when a staking pool is disabled (deactivated).
     * @param poolId The ID of the staking pool that was disabled.
     */
    event StakingPoolDisabled(uint256 indexed poolId);

    /* ============ Custom Errors ============ */

    /// @notice Emitted when the pool ID provided is out of range or otherwise invalid.
    error InvalidPoolId();

    /// @notice Emitted when attempting to disable a pool that is already inactive.
    error PoolAlreadyInactive();

    /// @notice Emitted when the yearly rate is invalid.
    error InvalidYearlyRate(uint16 rate);

    /// @notice Emitted when the cooldown is invalid.
    error InvalidRewardCooldownPeriod(uint32 cooldownPeriod);

    /// @notice Emitted when the balance is insufficient for a specific operation.
    error InsufficientBalance(uint256 amount);

    /// @notice Emitted when a passed value is greater than the maximum value of uint224.
    error InvalidUInt224();

    /// @notice Emitted when a user attempts to claim rewards before the cooldown period has elapsed.
    error RewardCooldownPeriodNotCompleted(uint32 remainingCooldown);

    /// @notice Emitted when a function is called by an address that is not authorized to perform the action.
    error Unauthorized();

    /**
     * @notice Thrown when adding a new staking pool with a multiplierMax value below 1e6 or otherwise invalid.
     */
    error InvalidMultiplierMax();

    /**
     * @notice Thrown when adding a new staking pool with a zero or otherwise invalid time threshold.
     */
    error InvalidTimeThreshold();

    /**
     * @notice Thrown when an operation requires the sender to have an active stake, but none is found.
     */
    error NotStaker();

    /**
     * @notice Thrown when trying to unstake an amount that exceeds the user's currently staked balance.
     */
    error NotEnoughStaked();

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

    /**
     * @notice Updates the reward cooldown period required between reward claims.
     * @dev Only the owner can call this function.
     * @param newRewardCooldownPeriod_ The new reward cooldown period in seconds.
     */
    function setRewardCooldownPeriod(uint32 newRewardCooldownPeriod_) external;

    /**
     * @notice Adds a new staking pool with a specified LP token, maximum multiplier, and time threshold.
     * @dev Only callable by the contract owner. Reverts if the multiplier or threshold are invalid.
     * @param lpToken_ The address of the LP token for this staking pool.
     * @param multiplierMax_ The maximum staking multiplier (scaled by 1e6).
     * @param timeThreshold_ The time threshold in seconds required to reach the maximum multiplier.
     */
    function addStakingPool(address lpToken_, uint32 multiplierMax_, uint32 timeThreshold_) external;

    /**
     * @notice Stakes the specified amount of LP tokens into a given pool.
     * @dev Transfers LP tokens from the caller to the contract and updates the staker's data.
     *      Reverts if the pool ID is invalid or the amount is zero.
     * @param poolId_ The ID of the staking pool in the `pools` array.
     * @param amount_ The amount of LP tokens to stake.
     */
    function stakeLiquidity(uint256 poolId_, uint256 amount_) external;

    /**
     * @notice Unstakes a specified amount of LP tokens from a given pool.
     * @dev Transfers the unstaked LP tokens back to the user and updates staking data.
     *      Reverts if the user has insufficient staked balance or the pool ID is invalid.
     * @param poolId_ The ID of the staking pool in the `pools` array.
     * @param amount_ The amount of LP tokens to unstake.
     */
    function unstakeLiquidity(uint256 poolId_, uint256 amount_) external;
}
