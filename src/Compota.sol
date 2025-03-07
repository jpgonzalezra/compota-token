// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { Owned } from "solmate/auth/Owned.sol";
import { ERC20Extended } from "@mzero-labs/ERC20Extended.sol";
import { IERC20 } from "@mzero-labs/interfaces/IERC20.sol";
import { ICompota } from "./interfaces/ICompota.sol";
import { IUniswapV2Pair } from "./interfaces/IUniswapV2Pair.sol";
import { Constants } from "./Constants.sol";
import { Helpers } from "./Helpers.sol";

/**
 * @title Compota
 * @dev Main contract implementing a yield-bearing ERC20 token.
 *      Allows base reward accrual and additional staking-based rewards.
 */
contract Compota is ICompota, ERC20Extended, Owned {
    /* ============ Variables ============ */

    uint16 public yearlyRate;

    uint32 public lastGlobalUpdateTimestamp;

    uint224 internal internalTotalSupply;

    uint224 public maxTotalSupply;

    uint32 public rewardCooldownPeriod;

    StakingPool[] public pools;

    address[] public activeStakers;

    // stakes[poolId][user]
    mapping(uint256 => mapping(address => UserStake)) public stakes;

    struct StakingPool {
        address lpToken;
        uint32 multiplierMax;
        uint32 timeThreshold;
        bool active;
    }

    struct UserStake {
        uint32 lpStakeStartTimestamp;
        uint224 lpBalanceStaked;
        uint32 periodStartTimestamp;
        uint32 lastStakeUpdateTimestamp;
        uint224 accumulatedLpBalancePerTime;
    }

    struct AccountBalance {
        // 1st slot
        // @dev This timestamp will work until approximately the year 2106
        uint32 lastUpdateTimestamp;
        uint224 value;
        // 2do slot
        uint32 periodStartTimestamp;
        uint224 accumulatedBalancePerTime;
    }

    mapping(address => AccountBalance) internal _balances;
    mapping(address => uint32) internal _latestClaimTimestamp;
    mapping(address => uint256) internal _activeStakerIndices;

    /* ============ Constructor ============ */

    constructor(
        string memory name_,
        string memory symbol_,
        uint16 yearlyRate_,
        uint32 rewardCooldownPeriod_,
        uint224 maxTotalSupply_
    ) ERC20Extended(name_, symbol_, 6) Owned(msg.sender) {
        setYearlyRate(yearlyRate_);
        setRewardCooldownPeriod(rewardCooldownPeriod_);
        maxTotalSupply = maxTotalSupply_;
    }

    /* ============ Interactive Functions ============ */

    /**
     * @notice Sets the yearly rate of interest.
     * @dev Only the owner can call this function. The new rate must be between
     *      `MIN_YEARLY_RATE` (1% APY) and `MAX_YEARLY_RATE` (40% APY).
     * @param newRate_ The new interest rate in basis points (BPS).
     */
    function setYearlyRate(uint16 newRate_) public onlyOwner {
        if (newRate_ < Constants.MIN_YEARLY_RATE || newRate_ > Constants.MAX_YEARLY_RATE) {
            revert InvalidYearlyRate(newRate_);
        }
        uint16 oldYearlyRate = yearlyRate;
        yearlyRate = newRate_;
        emit YearlyRateUpdated(oldYearlyRate, newRate_);
    }

    /**
     * @notice Updates the reward cooldown period required between reward claims.
     * @dev Only the owner can call this function.
     * @param newRewardCooldownPeriod_ The new reward cooldown period.
     */
    function setRewardCooldownPeriod(uint32 newRewardCooldownPeriod_) public onlyOwner {
        if (newRewardCooldownPeriod_ == 0) {
            revert InvalidRewardCooldownPeriod(newRewardCooldownPeriod_);
        }
        uint32 oldCooldownPeriod_ = rewardCooldownPeriod;
        rewardCooldownPeriod = newRewardCooldownPeriod_;
        emit RewardCooldownPeriodUpdated(oldCooldownPeriod_, newRewardCooldownPeriod_);
    }

    /**
     * @notice Adds a new staking pool with a specified LP token, maximum multiplier, and time threshold.
     * @dev Only callable by the contract owner. Reverts if the multiplier or threshold are invalid.
     */
    function addStakingPool(address lpToken_, uint32 multiplierMax_, uint32 timeThreshold_) external onlyOwner {
        if (multiplierMax_ < 1e6) revert InvalidMultiplierMax();
        if (timeThreshold_ == 0) revert InvalidTimeThreshold();
        pools.push(
            StakingPool({
                lpToken: lpToken_,
                multiplierMax: multiplierMax_,
                timeThreshold: timeThreshold_,
                active: true
            })
        );
    }

    /**
     * @notice Disables (deactivates) an existing staking pool by its pool ID.
     * @dev Only callable by the contract owner. Reverts if the pool ID is invalid or
     *      if the pool is already inactive.
     * @param poolId_ The ID of the staking pool in the `pools` array.
     */
    function disableStakingPool(uint256 poolId_) external onlyOwner {
        _validatePoolId(poolId_);
        StakingPool storage pool = pools[poolId_];
        if (!pool.active) {
            revert PoolAlreadyInactive();
        }

        pool.active = false;

        emit StakingPoolDisabled(poolId_);
    }

    /**
     * @notice Stakes the specified amount of LP tokens into a given pool.
     * @dev Updates the caller’s staking data and transfers LP tokens into this contract.
     *      Reverts if the pool ID is invalid or the amount is zero.
     */
    function stakeLiquidity(uint256 poolId_, uint256 amount_) external {
        _validatePoolId(poolId_);
        _revertIfInsufficientAmount(amount_);
        address caller = msg.sender;

        _updateRewards(caller);

        IERC20(pools[poolId_].lpToken).transferFrom(caller, address(this), amount_);

        uint32 timestamp = uint32(block.timestamp);
        UserStake storage stakeInfo = stakes[poolId_][caller];
        if (stakeInfo.lpBalanceStaked == 0) {
            stakeInfo.lpStakeStartTimestamp = timestamp;

            if (_activeStakerIndices[caller] == 0) {
                _activeStakerIndices[caller] = activeStakers.length + 1;
                activeStakers.push(caller);
            }

            if (stakeInfo.periodStartTimestamp == 0) {
                stakeInfo.periodStartTimestamp = timestamp;
                stakeInfo.lastStakeUpdateTimestamp = timestamp;
            }
        }

        _updateStakingAccumulation(poolId_, caller);

        stakeInfo.lpBalanceStaked += Helpers.toSafeUint224(amount_);
        stakeInfo.lastStakeUpdateTimestamp = timestamp;
    }

    /**
     * @notice Unstakes a specified amount of LP tokens from a given pool.
     * @dev Transfers LP tokens back to the user and updates staking data.
     *      Reverts if the user has insufficient staked amount.
     */
    function unstakeLiquidity(uint256 poolId_, uint256 amount_) external {
        _validatePoolId(poolId_);
        _revertIfInsufficientAmount(amount_);

        address caller = msg.sender;
        _updateRewards(caller);

        UserStake storage stakeInfo = stakes[poolId_][caller];
        uint224 staked = stakeInfo.lpBalanceStaked;
        if (staked < amount_) {
            revert NotEnoughStaked();
        }

        _updateStakingAccumulation(poolId_, caller);

        stakeInfo.lpBalanceStaked = staked - Helpers.toSafeUint224(amount_);
        stakeInfo.lastStakeUpdateTimestamp = uint32(block.timestamp);

        if (stakeInfo.lpBalanceStaked == 0) {
            stakeInfo.periodStartTimestamp = 0;
            stakeInfo.accumulatedLpBalancePerTime = 0;
            stakeInfo.lastStakeUpdateTimestamp = 0;
            stakeInfo.lpStakeStartTimestamp = 0;
            if (!_hasAnyActiveStake(caller)) {
                _removeActiveStaker(caller);
            }
        }

        IERC20(pools[poolId_].lpToken).transfer(caller, amount_);
    }

    /**
     * @notice Mints new tokens to a specified address.
     * @dev Only the owner can call this function.
     * @param to_ The address where the new tokens will be sent.
     * @param amount_ The number of tokens to mint.
     */
    function mint(address to_, uint256 amount_) external onlyOwner {
        _revertIfInvalidRecipient(to_);
        _revertIfInsufficientAmount(amount_);
        _updateRewardsWithoutCooldown(to_, uint32(block.timestamp));
        _mint(to_, amount_);
    }

    /**
     * @notice Burns tokens from the sender account.
     * @param amount_ The number of tokens to burn.
     */
    function burn(uint256 amount_) external {
        _revertIfInsufficientAmount(amount_);
        address caller = msg.sender;
        _revertIfInsufficientBalance(caller, amount_);
        _updateRewardsWithoutCooldown(caller, uint32(block.timestamp));
        _burn(caller, amount_);
    }

    /**
     * @notice Gets the total balance of an account, including accrued rewards.
     * @param account_ The address of the account to query the balance of.
     * @return The total balance of the account.
     * @inheritdoc IERC20
     */
    function balanceOf(address account_) external view virtual returns (uint256) {
        if (_balances[account_].lastUpdateTimestamp == 0) {
            return 0;
        }

        uint32 timestamp = uint32(block.timestamp);
        uint32 lastClaim = _latestClaimTimestamp[account_];
        if (timestamp - lastClaim < rewardCooldownPeriod) {
            return _balances[account_].value;
        }

        return
            _balances[account_].value +
            _calculatePendingBaseRewards(account_, timestamp) +
            _calculatePendingStakingRewards(account_, timestamp);
    }

    /**
     * @notice Returns the user’s pending base rewards.
     * @param account_ The address of the user to query.
     * @return The total amount of base rewards accrued so far, in the smallest unit of the token.
     */
    function getUserBaseRewards(address account_) external view returns (uint256) {
        return _calculatePendingBaseRewards(account_, uint32(block.timestamp));
    }

    /**
     * @notice Calculates the user’s pending base rewards at a given timestamp.
     * @dev Returns how many tokens would be accrued from simply holding Compota.
     */
    function calculateBaseRewards(address account_, uint32 currentTimestamp_) external view returns (uint256) {
        return _calculatePendingBaseRewards(account_, currentTimestamp_);
    }

    /**
     * @notice Returns the user’s pending staking rewards.
     * @param account_ The address of the user to query.
     * @return The total amount of staking rewards accrued so far, in the smallest unit of the token.
     */
    function getUserStakingRewards(address account_) external view returns (uint256) {
        return _calculatePendingStakingRewards(account_, uint32(block.timestamp));
    }

    /**
     * @notice Calculates the user’s pending staking rewards at a given timestamp.
     * @dev Returns how many tokens would be earned from staking LP tokens, factoring in multipliers.
     */
    function calculateStakingRewards(address account_, uint32 currentTimestamp_) external view returns (uint256) {
        return _calculatePendingStakingRewards(account_, currentTimestamp_);
    }

    /**
     * @notice Returns the user’s total pending rewards.
     * @param account_ The address of the user to query.
     * @return The total amount of unminted rewards the user would receive upon the next reward
     *         update or claim, in the smallest unit of the token.
     */
    function getUserTotalRewards(address account_) external view returns (uint256) {
        uint32 timestamp = uint32(block.timestamp);
        return _calculatePendingBaseRewards(account_, timestamp) + _calculatePendingStakingRewards(account_, timestamp);
    }

    /**
     * @notice Returns the total supply of tokens currently minted and in circulation.
     * @dev This value includes tokens that have been claimed and minted, but excludes unclaimed rewards.
     * @return totalSupply_ The total supply of minted tokens.
     * @inheritdoc IERC20
     */
    function totalSupply() public view returns (uint256 totalSupply_) {
        return uint256(internalTotalSupply);
    }

    /**
     * @notice Returns the total circulating supply of tokens.
     * @dev This value includes all minted tokens plus unclaimed rewards (both base and staking rewards).
     *      Unclaimed rewards are calculated dynamically.
     * @return circulatingSupply The total supply of tokens currently in circulation, including rewards.
     */
    function totalCirculatingSupply() external view virtual returns (uint256 circulatingSupply) {
        return uint256(internalTotalSupply + _calculateGlobalBaseRewards() + _calculateGlobalStakingRewards());
    }

    /**
     * @notice Returns the maximum possible supply of tokens, including all future rewards.
     * @dev This value is fixed and represents the absolute upper limit of token issuance.
     * @return maxSupply The total number of tokens that can ever exist.
     */
    function maxProjectedSupply() external view returns (uint224 maxSupply) {
        return maxTotalSupply;
    }

    /**
     * @notice Returns the total number of staking pools available in the contract.
     * @dev The count is determined by the length of the `pools` array.
     * @return The total number of staking pools.
     */
    function getPoolCounts() external view returns (uint256) {
        return pools.length;
    }

    /**
     * @notice Returns the total number of active stakers currently participating in the staking system.
     * @dev The count is determined by the length of the `activeStakers` array.
     * @return The total number of active stakers.
     */
    function getActiveStakerCounts() external view returns (uint256) {
        return activeStakers.length;
    }

    /**
     * @notice Claims the accumulated rewards for the sender.
     * @dev It can only be called by the owner of the rewards.
     */
    function claimRewards() external {
        address caller = msg.sender;
        _updateRewards(caller);
    }

    /**
     * @notice Computes a cubic time-based multiplier for staking rewards.
     * @dev    As the staking duration grows closer to the `timeThreshold_`,
     *         the multiplier smoothly transitions from 1× up to `multiplierMax_`.
     * @param multiplierMax_  The maximum possible multiplier, scaled by 1e6.
     * @param timeThreshold_  The threshold in seconds for reaching the full multiplier.
     * @param timeStaked_     The actual time (in seconds) the user has staked.
     * @return A scaled multiplier (1e6 base) that rewards users incrementally
     *         based on how long they have staked relative to `timeThreshold_`.
     */
    function calculateCubicMultiplier(
        uint256 multiplierMax_,
        uint256 timeThreshold_,
        uint256 timeStaked_
    ) public pure returns (uint256) {
        if (timeStaked_ >= timeThreshold_) {
            return multiplierMax_;
        }
        uint256 ratio = (timeStaked_ * 1e6) / timeThreshold_;
        uint256 ratioCubed = (ratio * ratio * ratio) / (1e6 * 1e6);

        uint256 one = 1e6;
        uint256 cubicMultiplier = one + ((multiplierMax_ - one) * ratioCubed) / one;

        return cubicMultiplier;
    }

    /**
     * @notice Returns the current multiplier for a user in a specific pool, based on how long they've been staked.
     * @dev    Uses the same math as `calculateCubicMultiplier`, factoring in
     *         `lpStakeStartTimestamp` to see how much time has elapsed for that user.
     * @param account_    The address of the user.
     * @param poolId_  The ID of the staking pool in the `pools` array.
     * @return currentMultiplier A scaled multiplier (base 1e6) indicating the user's boost.
     */
    function getCurrentMultiplier(address account_, uint256 poolId_) external view returns (uint256) {
        if (poolId_ >= pools.length) {
            return 1e6;
        }

        UserStake memory stakeInfo = stakes[poolId_][account_];
        if (stakeInfo.lpBalanceStaked == 0) {
            return 1e6;
        }

        uint256 timeStaked = (stakeInfo.lpStakeStartTimestamp > 0)
            ? block.timestamp - stakeInfo.lpStakeStartTimestamp
            : 0;

        StakingPool memory pool = pools[poolId_];
        return this.calculateCubicMultiplier(pool.multiplierMax, pool.timeThreshold, timeStaked);
    }

    /**
     * @notice Checks if a user's rewards are claimable at this moment.
     * @dev    If the cooldown has passed, it returns `(true, 0)`.
     *         Otherwise, it returns `(false, timeRemaining)`,
     *         where `timeRemaining` is how many seconds are left until they can claim.
     * @param account_ The address of the user to query.
     * @return timeLeft  The number of seconds remaining until the user can claim if not claimable.
     *                   Returns `0` if claimable is `true`.
     */
    function isClaimable(address account_) external view returns (uint32 timeLeft) {
        uint32 lastClaim = _latestClaimTimestamp[account_];
        uint32 elapsed = uint32(block.timestamp) - lastClaim;
        timeLeft = (elapsed >= rewardCooldownPeriod) ? 0 : rewardCooldownPeriod - elapsed;
    }

    /* ============ Internal Interactive Functions ============ */

    /**
     * @notice Checks if the given user still has tokens staked in at least one of the pools.
     * @param user The address of the user to be queried.
     * @return A boolean indicating whether the user has an active stake in at least one pool.
     */
    function _hasAnyActiveStake(address user) internal view returns (bool) {
        for (uint256 i = 0; i < pools.length; i++) {
            if (stakes[i][user].lpBalanceStaked > 0) {
                return true;
            }
        }
        return false;
    }

    /**
     * @dev Internal function that removes a user from the active stakers list once fully unstaked.
     *      Reverts if the user is not currently an active staker.
     */
    function _removeActiveStaker(address staker_) internal {
        uint256 indexPlusOne = _activeStakerIndices[staker_];
        if (indexPlusOne == 0) {
            revert NotStaker();
        }

        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = activeStakers.length - 1;
        address lastStaker = activeStakers[lastIndex];

        activeStakers[index] = lastStaker;
        _activeStakerIndices[lastStaker] = index + 1;

        activeStakers.pop();

        delete _activeStakerIndices[staker_];
    }

    /**
     * @notice Transfers tokens between accounts
     * @param sender_ The address of the account from which tokens will be transferred.
     * @param recipient_ The address of the account to which tokens will be transferred.
     * @param amount_ The amount of tokens to be transferred.
     */
    function _transfer(address sender_, address recipient_, uint256 amount_) internal override {
        _revertIfInvalidRecipient(recipient_);

        // Update rewards for both sender and recipient
        _updateRewards(sender_);
        _revertIfInsufficientBalance(sender_, amount_);

        _updateRewards(recipient_);

        uint224 amount224 = Helpers.toSafeUint224(amount_);
        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint224 value.
        unchecked {
            _balances[sender_].value -= amount224;
            _balances[recipient_].value += amount224;
        }

        emit Transfer(sender_, recipient_, amount_);
    }

    /**
     * @notice Mints new tokens and assigns them to the specified account.
     * @param to_ The address of the account receiving the newly minted tokens.
     * @param amount_ The amount of tokens to mint.
     */
    function _mint(address to_, uint256 amount_) internal virtual {
        if (internalTotalSupply + amount_ > maxTotalSupply) {
            amount_ = maxTotalSupply - internalTotalSupply;
        }

        if (amount_ == 0) {
            return;
        }

        uint224 amount224 = Helpers.toSafeUint224(amount_);
        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint224 value.
        unchecked {
            internalTotalSupply += amount224;
            _balances[to_].value += amount224;
        }

        emit Transfer(address(0), to_, amount_);
    }

    /**
     * @notice Burns tokens from the specified account.
     * @param from_ The address of the account from which tokens will be burned.
     * @param amount_ The amount of tokens to burn.
     */
    function _burn(address from_, uint256 amount_) internal virtual {
        uint224 amount224 = Helpers.toSafeUint224(amount_);
        // Cannot underflow because a user's balance
        // will never be larger than the total supply.
        unchecked {
            _balances[from_].value -= amount224;
            internalTotalSupply -= amount224;
        }
        emit Transfer(from_, address(0), amount_);
    }

    /**
     * @dev Updates rewards for an account without respecting the cooldown period,
     *      minting any accrued base and staking rewards immediately.
     */
    function _updateRewardsWithoutCooldown(address accountAddress_, uint32 timestamp_) internal virtual {
        AccountBalance storage account = _balances[accountAddress_];
        uint32 lastUpdate = account.lastUpdateTimestamp;
        lastGlobalUpdateTimestamp = timestamp_;

        if (lastUpdate == 0) {
            account.periodStartTimestamp = timestamp_;
            account.lastUpdateTimestamp = timestamp_;
            _latestClaimTimestamp[accountAddress_] = timestamp_;
            emit StartedEarningRewards(accountAddress_);
            return;
        }

        uint256 pendingBaseRewards = _calculatePendingBaseRewards(accountAddress_, timestamp_);
        uint256 stakingRewards = _calculatePendingStakingRewards(accountAddress_, timestamp_);

        uint256 totalRewards = pendingBaseRewards + stakingRewards;
        if (totalRewards > 0) {
            uint256 remaining = maxTotalSupply > internalTotalSupply ? (maxTotalSupply - internalTotalSupply) : 0;
            if (totalRewards > remaining) {
                totalRewards = remaining;
            }
            if (totalRewards > 0) {
                _mint(accountAddress_, totalRewards);
            }
        }

        account.periodStartTimestamp = timestamp_;
        account.accumulatedBalancePerTime = 0;
        account.lastUpdateTimestamp = timestamp_;

        _resetStakingPeriods(accountAddress_, timestamp_);
        _latestClaimTimestamp[accountAddress_] = timestamp_;
    }

    /**
     * @notice Updates the accrued rewards for the specified account.
     * @param account_ The address of the account for which rewards will be updated.
     */
    function _updateRewards(address account_) internal virtual {
        uint32 timestamp = uint32(block.timestamp);

        uint32 latestClaim = _latestClaimTimestamp[account_];
        if (timestamp - latestClaim < rewardCooldownPeriod) {
            AccountBalance storage acc = _balances[account_];
            if (acc.lastUpdateTimestamp == 0) {
                acc.lastUpdateTimestamp = timestamp;
                acc.periodStartTimestamp = timestamp;
                emit StartedEarningRewards(account_);
                return;
            }

            uint32 elapsed = timestamp - acc.lastUpdateTimestamp;
            if (elapsed > 0 && acc.value > 0) {
                acc.accumulatedBalancePerTime += acc.value * elapsed;
            }
            acc.lastUpdateTimestamp = timestamp;

            _accumulateStakingTime(account_);
            return;
        }
        _updateRewardsWithoutCooldown(account_, timestamp);
    }

    /**
     * @dev Accumulates the user’s staked LP amount over time for accurate reward calculations.
     *      Called before stake updates to refresh the user’s staking data.
     */
    function _updateStakingAccumulation(uint256 poolId_, address account_) internal {
        uint32 timestamp = uint32(block.timestamp);
        UserStake storage stakeInfo = stakes[poolId_][account_];
        if (stakeInfo.lastStakeUpdateTimestamp == 0) {
            stakeInfo.lastStakeUpdateTimestamp = timestamp;
            if (stakeInfo.periodStartTimestamp == 0) {
                stakeInfo.periodStartTimestamp = timestamp;
            }
            return;
        }

        uint32 elapsed = timestamp - stakeInfo.lastStakeUpdateTimestamp;
        if (elapsed > 0 && stakeInfo.lpBalanceStaked > 0) {
            stakeInfo.accumulatedLpBalancePerTime += stakeInfo.lpBalanceStaked * elapsed;
        }
    }

    /**
     * @dev Iterates over all pools to update each active stake’s elapsed time.
     *      Useful when partial time elapses before a cooldown completes.
     */
    function _accumulateStakingTime(address account_) internal {
        uint256 poolLength = pools.length;
        uint32 timestamp = uint32(block.timestamp);

        for (uint256 i = 0; i < poolLength; i++) {
            UserStake storage stakeInfo = stakes[i][account_];
            if (stakeInfo.lpBalanceStaked == 0 || stakeInfo.lastStakeUpdateTimestamp == 0) continue;

            uint32 elapsed = timestamp - stakeInfo.lastStakeUpdateTimestamp;
            if (elapsed > 0 && stakeInfo.lpBalanceStaked > 0) {
                stakeInfo.accumulatedLpBalancePerTime += stakeInfo.lpBalanceStaked * elapsed;
                stakeInfo.lastStakeUpdateTimestamp = timestamp;
            }
        }
    }

    /**
     * @dev Resets the staking periods for a user in each pool, typically after rewards are claimed
     *      or when cooldown has ended, ensuring a fresh accumulation interval.
     */
    function _resetStakingPeriods(address account_, uint32 timestamp_) internal {
        uint256 poolLength = pools.length;
        for (uint256 i = 0; i < poolLength; i++) {
            UserStake storage stakeInfo = stakes[i][account_];
            if (stakeInfo.lpBalanceStaked == 0) {
                continue;
            }
            stakeInfo.periodStartTimestamp = timestamp_;
            stakeInfo.accumulatedLpBalancePerTime = 0;
            stakeInfo.lastStakeUpdateTimestamp = timestamp_;
        }
    }

    /**
     * @dev Computes how many base (holding) rewards a user has accrued since their last update,
     *      using the user’s average token balance over the elapsed period.
     */
    function _calculatePendingBaseRewards(address account_, uint32 currentTimestamp_) internal view returns (uint256) {
        AccountBalance memory account = _balances[account_];

        if (account.periodStartTimestamp == 0) {
            return 0;
        }

        uint32 elapsedSinceLastUpdate = currentTimestamp_ > account.lastUpdateTimestamp
            ? currentTimestamp_ - account.lastUpdateTimestamp
            : 0;

        uint224 tempAccumulatedBalancePerTime = account.accumulatedBalancePerTime;
        if (elapsedSinceLastUpdate > 0 && account.value > 0) {
            tempAccumulatedBalancePerTime += account.value * elapsedSinceLastUpdate;
        }

        uint32 totalElapsed = currentTimestamp_ > account.periodStartTimestamp
            ? currentTimestamp_ - account.periodStartTimestamp
            : 0;

        if (totalElapsed == 0 || tempAccumulatedBalancePerTime == 0) {
            return 0;
        }

        uint224 avgBalance = tempAccumulatedBalancePerTime / totalElapsed;
        return _calculateRewards(avgBalance, totalElapsed);
    }

    /**
     * @dev Aggregates the staking rewards for all pools for a given user, factoring in
     *      time-weighted staked amounts, LP reserves, and multipliers.
     */
    function _calculatePendingStakingRewards(
        address account_,
        uint32 currentTimestamp_
    ) internal view returns (uint256) {
        uint256 totalStakingRewards = 0;
        uint256 poolLength = pools.length;
        for (uint256 poolId = 0; poolId < poolLength; poolId++) {
            if (!pools[poolId].active) {
                continue;
            }
            totalStakingRewards += _calculatePoolPendingStakingRewards(poolId, account_, currentTimestamp_);
        }
        return totalStakingRewards;
    }

    /**
     * @notice Calculates the user's pending staking rewards for a specific pool.
     * @dev    Combines average LP staked, LP token reserves, and the cubic multiplier
     *         to find the portion of `Compota` accrued. Returns 0 if conditions (e.g.,
     *         no staking, zero reserves, or zero LP supply) are not met.
     * @param poolId_           The ID of the staking pool in the `pools` array.
     * @param account_          The user's address.
     * @param currentTimestamp_ The current block timestamp for reward calculation.
     * @return The amount of `Compota` tokens earned from staking in this pool
     *         since the last update, without minting them yet.
     */
    function _calculatePoolPendingStakingRewards(
        uint256 poolId_,
        address account_,
        uint32 currentTimestamp_
    ) internal view returns (uint256) {
        UserStake memory stakeInfo = stakes[poolId_][account_];
        if (stakeInfo.lpBalanceStaked == 0 || stakeInfo.periodStartTimestamp == 0) return 0;

        uint32 elapsedSinceLastUpdate = currentTimestamp_ > stakeInfo.lastStakeUpdateTimestamp
            ? currentTimestamp_ - stakeInfo.lastStakeUpdateTimestamp
            : 0;

        uint224 tempAccumulated = stakeInfo.accumulatedLpBalancePerTime;
        if (elapsedSinceLastUpdate > 0 && stakeInfo.lpBalanceStaked > 0) {
            tempAccumulated += stakeInfo.lpBalanceStaked * elapsedSinceLastUpdate;
        }

        uint32 totalElapsed = currentTimestamp_ > stakeInfo.periodStartTimestamp
            ? currentTimestamp_ - stakeInfo.periodStartTimestamp
            : 0;

        if (totalElapsed == 0 || tempAccumulated == 0) return 0;

        uint224 avgLpStaked = tempAccumulated / totalElapsed;
        uint256 timeStaked = stakeInfo.lpStakeStartTimestamp > 0
            ? (currentTimestamp_ - stakeInfo.lpStakeStartTimestamp)
            : 0;

        StakingPool memory pool = pools[poolId_];
        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(pool.lpToken).getReserves();
        address token0 = IUniswapV2Pair(pool.lpToken).token0();
        uint256 compotaReserve = (token0 == address(this)) ? reserve0 : reserve1;

        if (compotaReserve == 0) {
            return 0;
        }

        uint256 lpTotalSupply = IERC20(pool.lpToken).totalSupply();
        if (lpTotalSupply == 0) return 0;

        uint256 compotaPortion = (uint256(avgLpStaked) * compotaReserve) / lpTotalSupply;
        uint256 cubicMultiplier = this.calculateCubicMultiplier(pool.multiplierMax, pool.timeThreshold, timeStaked);

        uint256 rewardsStaking = (compotaPortion * yearlyRate * totalElapsed * cubicMultiplier) /
            (Constants.SCALE_FACTOR * uint256(Constants.SECONDS_PER_YEAR) * 1e6);

        return rewardsStaking;
    }

    function getGlobalRewards() external view returns (uint224) {
        return _calculateGlobalBaseRewards() + _calculateGlobalStakingRewards();
    }

    /**
     * @notice Calculates the total current accrued rewards for the entire supply since the last update.
     * @return The amount of rewards accrued since the last update.
     */
    function _calculateGlobalBaseRewards() internal view returns (uint224) {
        if (lastGlobalUpdateTimestamp == 0) return 0;
        return _calculateRewards(internalTotalSupply, block.timestamp - lastGlobalUpdateTimestamp);
    }

    /**
     * @notice Calculates the total current accrued staking rewards for the entire supply since the last update.
     * @return The amount of staking rewards accrued since the last update.
     */
    function _calculateGlobalStakingRewards() internal view returns (uint224) {
        uint256 totalStakingRewards = 0;
        uint32 timestamp = uint32(block.timestamp);
        uint256 activeStakersLength = activeStakers.length;
        uint256 poolsLength = pools.length;

        for (uint256 i = 0; i < activeStakersLength; i++) {
            address staker = activeStakers[i];
            for (uint256 poolId = 0; poolId < poolsLength; poolId++) {
                if (!pools[poolId].active) {
                    continue;
                }
                totalStakingRewards += _calculatePoolPendingStakingRewards(poolId, staker, timestamp);
            }
        }

        return Helpers.toSafeUint224(totalStakingRewards);
    }

    /**
     * @notice Generalized function to calculate rewards based on an amount and a timestamp.
     * @param amount_ The amount of tokens to calculate rewards for.
     * @param elapsed_ The time elapsed in seconds.
     * @return The amount of rewards accrued.
     */
    function _calculateRewards(uint224 amount_, uint256 elapsed_) internal view returns (uint224) {
        if (internalTotalSupply == maxTotalSupply) return 0;
        if (elapsed_ == 0) return 0;

        uint256 mul;
        unchecked {
            mul = amount_ * elapsed_ * yearlyRate;
        }

        return Helpers.toSafeUint224(mul / (Constants.SCALE_FACTOR * uint256(Constants.SECONDS_PER_YEAR)));
    }

    /**
     * @dev Checks whether `caller_` has enough balance (including accrued rewards).
     *      Reverts if the amount to spend/burn exceeds current holdings.
     */
    function _revertIfInsufficientBalance(address caller_, uint256 amount_) internal view {
        uint224 balance = _balances[caller_].value;
        if (balance < amount_) revert InsufficientBalance(amount_);
    }

    /**
     * @dev Reverts if the specified amount is zero, used to block 0-value stake, mint, transfer, etc.
     */
    function _revertIfInsufficientAmount(uint256 amount_) internal pure {
        if (amount_ == 0) revert InsufficientAmount(amount_);
    }

    /**
     * @dev Reverts if `recipient_` is the zero address. Used to prevent sending tokens to `address(0)`.
     */
    function _revertIfInvalidRecipient(address recipient_) internal pure {
        if (recipient_ == address(0)) revert InvalidRecipient(recipient_);
    }

    /**
     * @dev Ensures the given pool ID is valid (i.e., within the range of existing `pools`).
     *      Reverts with `InvalidPoolId()` if out of range.
     */
    function _validatePoolId(uint256 poolId_) internal view {
        if (poolId_ >= pools.length) revert InvalidPoolId();
    }
}
