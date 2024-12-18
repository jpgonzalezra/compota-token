// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.23;

import { console } from "forge-std/console.sol";
import { Owned } from "solmate/auth/Owned.sol";
import { ERC20Extended } from "@mzero-labs/ERC20Extended.sol";
import { IERC20 } from "@mzero-labs/interfaces/IERC20.sol";
import { ICompota } from "./interfaces/ICompota.sol";
import { IUniswapV2Pair } from "./interfaces/IUniswapV2Pair.sol";

/**
 * @title Compota
 * @dev ERC20 interest-bearing token that continuously accrues yield to its holders.
 */
contract Compota is ICompota, ERC20Extended, Owned {
    /* ============ Variables ============ */

    /// @notice Scale factor used to convert basis points (bps) into decimal fractions.
    uint16 internal constant SCALE_FACTOR = 10_000; // Ex, 100 bps (1%) is converted to 0.01 by dividing by 10,000

    /// @notice The number of seconds in a year.
    uint32 internal constant SECONDS_PER_YEAR = 31_536_000;

    /// @notice The minimum yearly rate of interest in basis points (bps).
    uint16 public constant MIN_YEARLY_RATE = 100; // This represents a 1% annual percentage yield (APY).

    /// @notice The maximum yearly rate of interest in basis points (bps).
    uint16 public constant MAX_YEARLY_RATE = 4_000; // This represents a 40% annual percentage yield (APY).

    uint16 public yearlyRate;

    uint32 public lastGlobalUpdateTimestamp;

    uint224 internal internalTotalSupply;

    uint224 public maxTotalSupply;

    uint32 public rewardCooldownPeriod;

    StakingPool[] public pools;

    address[] public activeStakers;
    mapping(address => bool) private isActiveStaker;

    // stakes[poolId][user]
    mapping(uint256 => mapping(address => UserStake)) public stakes;

    struct StakingPool {
        address lpToken;
        uint32 multiplierMax;
        uint32 timeThreshold;
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

    /* ============ Constructor ============ */

    constructor(
        uint16 yearlyRate_,
        uint32 rewardCooldownPeriod_,
        uint224 maxTotalSupply_
    ) ERC20Extended("Compota Token", "COMPOTA", 6) Owned(msg.sender) {
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
        if (newRate_ < MIN_YEARLY_RATE || newRate_ > MAX_YEARLY_RATE) {
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

    // TODO: DOC
    function addStakingPool(address lpToken_, uint32 multiplierMax_, uint32 timeThreshold_) external onlyOwner {
        require(multiplierMax_ >= 1e6, "multiplierMax < 1");
        require(timeThreshold_ > 0, "timeThreshold = 0");
        pools.push(StakingPool({ lpToken: lpToken_, multiplierMax: multiplierMax_, timeThreshold: timeThreshold_ }));
    }

    function stakeLiquidity(uint256 poolId_, uint256 amount_) external {
        require(poolId_ < pools.length, "Invalid poolId");
        require(amount_ > 0, "amount=0");
        address caller = msg.sender;

        _updateRewards(caller);

        IERC20(pools[poolId_].lpToken).transferFrom(caller, address(this), amount_);

        UserStake storage stakeInfo = stakes[poolId_][caller];
        if (stakeInfo.lpBalanceStaked == 0) {
            stakeInfo.lpStakeStartTimestamp = uint32(block.timestamp);

            if (!isActiveStaker[caller]) {
                activeStakers.push(caller);
                isActiveStaker[caller] = true;
            }

            // Initialize staking period if not set
            if (stakeInfo.periodStartTimestamp == 0) {
                stakeInfo.periodStartTimestamp = uint32(block.timestamp);
                stakeInfo.lastStakeUpdateTimestamp = uint32(block.timestamp);
            }
        }

        // Before modifying the balance, update the staking accumulation
        _updateStakingAccumulation(poolId_, caller);

        stakeInfo.lpBalanceStaked += toSafeUint224(amount_);
        stakeInfo.lastStakeUpdateTimestamp = uint32(block.timestamp);
    }

    function unstakeLiquidity(uint256 poolId, uint256 amount_) external {
        require(poolId < pools.length, "Invalid poolId");
        require(amount_ > 0, "amount=0");

        address caller = msg.sender;
        _updateRewards(caller);

        UserStake storage stakeInfo = stakes[poolId][caller];
        uint224 staked = stakeInfo.lpBalanceStaked;
        require(staked >= amount_, "Not enough staked");

        // Update staking accumulation before modifying the balance
        _updateStakingAccumulation(poolId, caller);

        stakeInfo.lpBalanceStaked = staked - toSafeUint224(amount_);
        stakeInfo.lastStakeUpdateTimestamp = uint32(block.timestamp);

        if (stakeInfo.lpBalanceStaked == 0) {
            stakeInfo.periodStartTimestamp = 0;
            stakeInfo.accumulatedLpBalancePerTime = 0;
            stakeInfo.lastStakeUpdateTimestamp = 0;
            stakeInfo.lpStakeStartTimestamp = 0;
            _removeActiveStaker(caller);
        }

        IERC20(pools[poolId].lpToken).transfer(caller, amount_);
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
        _updateRewardsWithoutCooldown(caller, uint32(block.timestamp));
        _revertIfInsufficientBalance(caller, amount_);
        _burn(caller, amount_);
    }

    /**
     * @notice Gets the total balance of an account, including accrued rewards.
     * @param account_ The address of the account to query the balance of.
     * @return The total balance of the account.
     * @inheritdoc IERC20
     */
    function balanceOf(address account_) external view override returns (uint256) {
        uint32 timestamp = uint32(block.timestamp);
        return
            _balances[account_].value +
            _calculatePendingBaseRewards(account_, timestamp) +
            _calculatePendingStakingRewards(account_, timestamp);
    }

    /**
     * @notice Retrieves the total supply of tokens, including unclaimed rewards.
     * @return totalSupply_ The total supply of tokens, including unclaimed rewards.
     * @inheritdoc IERC20
     */
    function totalSupply() external view returns (uint256 totalSupply_) {
        return uint256(internalTotalSupply + _calculateGlobalBaseRewards() + _calculateGlobalStakingRewards());
    }

    /**
     * @notice Claims the accumulated rewards for the sender.
     * @dev It can only be called by the owner of the rewards.
     */
    function claimRewards() external {
        address caller = msg.sender;
        _updateRewards(caller);
    }

    /* ============ Internal Interactive Functions ============ */

    // TODO: doc
    function _removeActiveStaker(address staker) internal {
        uint256 length = activeStakers.length;
        for (uint256 i = 0; i < length; i++) {
            if (activeStakers[i] == staker) {
                activeStakers[i] = activeStakers[length - 1];
                activeStakers.pop();
                isActiveStaker[staker] = false;
                break;
            }
        }
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
        _updateRewards(recipient_);

        _balances[sender_].value -= toSafeUint224(amount_);

        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint224 value.
        unchecked {
            _balances[recipient_].value += toSafeUint224(amount_);
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

        internalTotalSupply += toSafeUint224(amount_);

        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint224 value.
        unchecked {
            _balances[to_].value += toSafeUint224(amount_);
        }

        emit Transfer(address(0), to_, amount_);
    }

    /**
     * @notice Burns tokens from the specified account.
     * @param from_ The address of the account from which tokens will be burned.
     * @param amount_ The amount of tokens to burn.
     */
    function _burn(address from_, uint256 amount_) internal virtual {
        _balances[from_].value -= toSafeUint224(amount_);

        // Cannot underflow because a user's balance
        // will never be larger than the total supply.
        unchecked {
            internalTotalSupply -= toSafeUint224(amount_);
        }
        emit Transfer(from_, address(0), amount_);
    }

    function _updateRewardsWithoutCooldown(address accountAddress, uint32 timestamp_) internal {
        AccountBalance storage account = _balances[accountAddress];
        uint32 lastUpdate = account.lastUpdateTimestamp;
        if (lastUpdate == 0) {
            account.periodStartTimestamp = timestamp_;
            account.lastUpdateTimestamp = timestamp_;
            _latestClaimTimestamp[accountAddress] = timestamp_;
            emit StartedEarningRewards(accountAddress);
            return;
        }

        uint256 pendingBaseRewards = _calculatePendingBaseRewards(accountAddress, timestamp_);
        uint256 stakingRewards = _calculatePendingStakingRewards(accountAddress, timestamp_);

        uint256 totalRewards = pendingBaseRewards + stakingRewards;
        if (totalRewards > 0) {
            uint256 remaining = maxTotalSupply > internalTotalSupply ? (maxTotalSupply - internalTotalSupply) : 0;
            if (totalRewards > remaining) {
                totalRewards = remaining;
            }
            if (totalRewards > 0) {
                _mint(accountAddress, totalRewards);
            }
        }

        account.periodStartTimestamp = timestamp_;
        account.accumulatedBalancePerTime = 0;
        account.lastUpdateTimestamp = timestamp_;

        for (uint256 i = 0; i < pools.length; i++) {
            UserStake storage stakeInfo = stakes[i][accountAddress];
            if (stakeInfo.lpBalanceStaked == 0) {
                continue;
            }
            stakeInfo.periodStartTimestamp = timestamp_;
            stakeInfo.accumulatedLpBalancePerTime = 0;
            stakeInfo.lastStakeUpdateTimestamp = timestamp_;
        }

        _latestClaimTimestamp[accountAddress] = timestamp_;
        lastGlobalUpdateTimestamp = timestamp_;
    }

    /**
     * @notice Updates the accrued rewards for the specified account.
     * @param account_ The address of the account for which rewards will be updated.
     */
    function _updateRewards(address account_) internal {
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

    function _updateStakingAccumulation(uint256 poolId_, address account_) internal {
        UserStake storage stakeInfo = stakes[poolId_][account_];
        if (stakeInfo.lastStakeUpdateTimestamp == 0) {
            stakeInfo.lastStakeUpdateTimestamp = uint32(block.timestamp);
            if (stakeInfo.periodStartTimestamp == 0) {
                stakeInfo.periodStartTimestamp = uint32(block.timestamp);
            }
            return;
        }

        uint32 elapsed = uint32(block.timestamp) - stakeInfo.lastStakeUpdateTimestamp;
        if (elapsed > 0 && stakeInfo.lpBalanceStaked > 0) {
            stakeInfo.accumulatedLpBalancePerTime += stakeInfo.lpBalanceStaked * elapsed;
        }
    }

    function _accumulateStakingTime(address account_) internal {
        for (uint256 i = 0; i < pools.length; i++) {
            UserStake storage stakeInfo = stakes[i][account_];
            if (stakeInfo.lpBalanceStaked == 0 || stakeInfo.lastStakeUpdateTimestamp == 0) continue;

            uint32 elapsed = uint32(block.timestamp) - stakeInfo.lastStakeUpdateTimestamp;
            if (elapsed > 0 && stakeInfo.lpBalanceStaked > 0) {
                stakeInfo.accumulatedLpBalancePerTime += stakeInfo.lpBalanceStaked * elapsed;
                stakeInfo.lastStakeUpdateTimestamp = uint32(block.timestamp);
            }
        }
    }

    function _resetStakingPeriods(address account_, uint32 timestamp_) internal {
        for (uint256 i = 0; i < pools.length; i++) {
            UserStake storage stakeInfo = stakes[i][account_];
            if (stakeInfo.lpBalanceStaked == 0) {
                continue;
            }
            stakeInfo.periodStartTimestamp = timestamp_;
            stakeInfo.accumulatedLpBalancePerTime = 0;
            stakeInfo.lastStakeUpdateTimestamp = timestamp_;
        }
    }

    function _calculatePendingBaseRewards(address account_, uint32 currentTimestamp_) internal view returns (uint256) {
        AccountBalance memory account = _balances[account_];

        if (account.periodStartTimestamp == 0) {
            return 0;
        }

        uint32 elapsedSinceLastUpdate = currentTimestamp_ > account.lastUpdateTimestamp
            ? currentTimestamp_ - account.lastUpdateTimestamp
            : 0;

        uint224 tempAccumulatedBalancePerTime = account.accumulatedBalancePerTime;
        console.log("elapsedSinceLastUpdate", elapsedSinceLastUpdate);
        console.log("tempAccumulatedBalancePerTime", tempAccumulatedBalancePerTime);
        if (elapsedSinceLastUpdate > 0 && account.value > 0) {
            tempAccumulatedBalancePerTime += account.value * elapsedSinceLastUpdate;
        }

        uint32 totalElapsed = currentTimestamp_ > account.periodStartTimestamp
            ? currentTimestamp_ - account.periodStartTimestamp
            : 0;

        if (totalElapsed == 0 || tempAccumulatedBalancePerTime == 0) {
            return 0;
        }

        console.log("totalElapsed", totalElapsed);
        uint224 avgBalance = tempAccumulatedBalancePerTime / totalElapsed;

        return _calculateRewards(avgBalance, totalElapsed);
    }

    function _calculatePendingStakingRewards(
        address account_,
        uint32 currentTimestamp_
    ) internal view returns (uint256) {
        uint256 totalStakingRewards = 0;
        for (uint256 i = 0; i < pools.length; i++) {
            totalStakingRewards += _calculatePoolPendingStakingRewards(i, account_, currentTimestamp_);
        }
        console.log(totalStakingRewards);
        return totalStakingRewards;
    }

    function _calculatePoolPendingStakingRewards(
        uint256 poolId,
        address account_,
        uint32 currentTimestamp_
    ) internal view returns (uint256) {
        UserStake memory stakeInfo = stakes[poolId][account_];
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

        StakingPool memory pool = pools[poolId];
        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(pool.lpToken).getReserves();
        address token0 = IUniswapV2Pair(pool.lpToken).token0();
        uint256 reserve = (token0 == address(this)) ? reserve0 : reserve1;

        if (reserve == 0) {
            return 0;
        }

        uint256 lpTotalSupply = IERC20(pool.lpToken).totalSupply();
        if (lpTotalSupply == 0) return 0;

        uint256 tokenQuantity = (uint256(avgLpStaked) * reserve) / lpTotalSupply;
        uint256 cubicMultiplier = _calculateCubicMultiplier(pool.multiplierMax, pool.timeThreshold, timeStaked);

        uint256 rewardsStaking = (tokenQuantity * yearlyRate * totalElapsed * cubicMultiplier) /
            (SCALE_FACTOR * uint256(SECONDS_PER_YEAR) * 1e6);

        return rewardsStaking;
    }

    function _calculateCubicMultiplier(
        uint256 multiplierMax,
        uint256 timeThreshold,
        uint256 timeStaked
    ) internal pure returns (uint256) {
        if (timeStaked >= timeThreshold) {
            return multiplierMax;
        }
        uint256 ratio = (timeStaked * 1e6) / timeThreshold;
        uint256 ratioCubed = (ratio * ratio * ratio) / (1e6 * 1e6);

        uint256 one = 1e6;
        uint256 cubicMultiplier = one + ((multiplierMax - one) * ratioCubed) / one;

        return cubicMultiplier;
    }

    /**
     * @notice Calculates the total current accrued rewards for the entire supply since the last update.
     * @return The amount of rewards accrued since the last update.
     */
    function _calculateGlobalBaseRewards() internal view returns (uint224) {
        if (lastGlobalUpdateTimestamp == 0) return 0;
        return _calculateRewards(internalTotalSupply, lastGlobalUpdateTimestamp);
    }

    /**
     * @notice Calculates the total current accrued staking rewards for the entire supply since the last update.
     * @return The amount of staking rewards accrued since the last update.
     */
    function _calculateGlobalStakingRewards() internal view returns (uint224) {
        uint256 totalStakingRewards = 0;

        uint32 timestamp = uint32(block.timestamp);
        for (uint256 i = 0; i < activeStakers.length; i++) {
            address staker = activeStakers[i];

            for (uint256 poolId = 0; poolId < pools.length; poolId++) {
                totalStakingRewards += _calculatePoolPendingStakingRewards(poolId, staker, timestamp);
            }
        }

        return toSafeUint224(totalStakingRewards);
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
        return toSafeUint224((amount_ * elapsed_ * yearlyRate) / (SCALE_FACTOR * uint256(SECONDS_PER_YEAR)));
    }

    /* ============ Helper Functions ============ */

    function _revertIfInsufficientBalance(address caller_, uint256 amount_) internal view {
        uint224 balance = _balances[caller_].value;
        if (balance < amount_) revert InsufficientBalance(amount_);
    }

    function _revertIfInsufficientAmount(uint256 amount_) internal pure {
        if (amount_ == 0) revert InsufficientAmount(amount_);
    }

    function _revertIfInvalidRecipient(address recipient_) internal pure {
        if (recipient_ == address(0)) revert InvalidRecipient(recipient_);
    }

    /**
     * @notice Casts a given uint256 value to a uint224,
     *         ensuring that it is less than or equal to the maximum uint224 value.
     * @param  n The value to check.
     * @return The value casted to uint224.
     * @dev Based on https://github.com/MZero-Labs/common/blob/main/src/libs/UIntMath.sol
     */
    function toSafeUint224(uint256 n) internal pure returns (uint224) {
        if (n > type(uint224).max) revert InvalidUInt224();
        return uint224(n);
    }
}
