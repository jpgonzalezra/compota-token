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
 * @dev     // TODO: doc
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

    // TODO: DOC
    function addStakingPool(address lpToken_, uint32 multiplierMax_, uint32 timeThreshold_) external onlyOwner {
        if (multiplierMax_ < 1e6) revert InvalidMultiplierMax();
        if (timeThreshold_ == 0) revert InvalidTimeThreshold();
        pools.push(StakingPool({ lpToken: lpToken_, multiplierMax: multiplierMax_, timeThreshold: timeThreshold_ }));
    }

    // TODO: DOC
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

    // TODO: doc
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
            _removeActiveStaker(caller);
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
    function balanceOf(address account_) external view override returns (uint256) {
        uint32 timestamp = uint32(block.timestamp);
        return
            _balances[account_].value +
            _calculatePendingBaseRewards(account_, timestamp) +
            _calculatePendingStakingRewards(account_, timestamp);
    }
    // TODO: doc
    function calculateBaseRewards(address account_, uint32 currentTimestamp_) external view returns (uint256) {
        return _calculatePendingBaseRewards(account_, currentTimestamp_);
    }
    // TODO: doc
    function calculateStakingRewards(address account_, uint32 currentTimestamp_) external view returns (uint256) {
        return _calculatePendingStakingRewards(account_, currentTimestamp_);
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

    // TODO: doc
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

    /* ============ Internal Interactive Functions ============ */

    // TODO: doc
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
        _revertIfInsufficientBalance(sender_, amount_);

        // Update rewards for both sender and recipient
        _updateRewards(sender_);
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

    // TODO: doc
    function _updateRewardsWithoutCooldown(address accountAddress_, uint32 timestamp_) internal {
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

    // TODO: doc
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
    // TODO: doc
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

    // TODO: doc
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

    // TODO: doc
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

    // TODO: doc
    function _calculatePendingStakingRewards(
        address account_,
        uint32 currentTimestamp_
    ) internal view returns (uint256) {
        uint256 totalStakingRewards = 0;
        uint256 poolLength = pools.length;
        for (uint256 i = 0; i < poolLength; i++) {
            totalStakingRewards += _calculatePoolPendingStakingRewards(i, account_, currentTimestamp_);
        }
        return totalStakingRewards;
    }

    // TODO: doc
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

    // TODO: doc
    function _revertIfInsufficientBalance(address caller_, uint256 amount_) internal view {
        uint224 balance = _balances[caller_].value;
        if (balance < amount_) revert InsufficientBalance(amount_);
    }

    // TODO: doc
    function _revertIfInsufficientAmount(uint256 amount_) internal pure {
        if (amount_ == 0) revert InsufficientAmount(amount_);
    }

    // TODO: doc
    function _revertIfInvalidRecipient(address recipient_) internal pure {
        if (recipient_ == address(0)) revert InvalidRecipient(recipient_);
    }

    // TODO: doc
    function _validatePoolId(uint256 poolId_) internal view {
        if (poolId_ >= pools.length) revert InvalidPoolId();
    }
}
