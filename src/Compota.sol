// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.23;

import { Owned } from "solmate/auth/Owned.sol";
import { ERC20Extended } from "@mzero-labs/ERC20Extended.sol";
import { IERC20 } from "@mzero-labs/interfaces/IERC20.sol";
import { ICompota } from "./intefaces/ICompota.sol";
import { IUniswapV2Pair } from "./intefaces/IUniswapV2Pair.sol";

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
    }

    struct AccountBalance {
        // 1st slot
        // @dev This timestamp will work until approximately the year 2106
        uint32 lastUpdateTimestamp;
        uint224 value;
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
        }
        stakeInfo.lpBalanceStaked += toSafeUint224(amount_);
    }

    function unstakeLiquidity(uint256 poolId, uint256 amount_) external {
        require(poolId < pools.length, "Invalid poolId");
        require(amount_ > 0, "amount=0");

        address caller = msg.sender;
        _updateRewards(caller);

        UserStake storage stakeInfo = stakes[poolId][caller];
        uint224 staked = stakeInfo.lpBalanceStaked;
        require(staked >= amount_, "Not enough staked");

        stakeInfo.lpBalanceStaked = staked - toSafeUint224(amount_);

        if (stakeInfo.lpBalanceStaked == 0) {
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
        _revertIfInsufficientBalance(msg.sender, amount_);
        _burn(caller, amount_);
    }

    /**
     * @notice Gets the total balance of an account, including accrued rewards.
     * @param account_ The address of the account to query the balance of.
     * @return The total balance of the account.
     * @inheritdoc IERC20
     */
    function balanceOf(address account_) external view override returns (uint256) {
        return
            _balances[account_].value +
            _calculatePendingBaseRewards(account_) +
            _calculateTotalUserStakingRewards(account_);
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

    function _updateRewardsWithoutCooldown(address account_, uint32 timestamp_) internal {
        lastGlobalUpdateTimestamp = timestamp_;

        if (_balances[account_].lastUpdateTimestamp == 0) {
            _balances[account_].lastUpdateTimestamp = timestamp_;
            _latestClaimTimestamp[account_] = timestamp_;
            emit StartedEarningRewards(account_);
            return;
        }

        uint256 baseRewards = _calculatePendingBaseRewards(account_);
        uint256 stakingRewards = _calculateTotalUserStakingRewards(account_);

        uint256 totalRewards = baseRewards + stakingRewards;
        if (totalRewards > 0) {
            _mint(account_, totalRewards);
        }
        _balances[account_].lastUpdateTimestamp = timestamp_;
    }

    /**
     * @notice Updates the accrued rewards for the specified account.
     * @param account_ The address of the account for which rewards will be updated.
     */
    function _updateRewards(address account_) internal {
        uint32 timestamp = uint32(block.timestamp);

        uint32 latestClaim = _latestClaimTimestamp[account_];
        if (timestamp - latestClaim < rewardCooldownPeriod) {
            return;
        }

        _latestClaimTimestamp[account_] = timestamp;
        _updateRewardsWithoutCooldown(account_, timestamp);
    }

    /**
     * @notice Calculates the current accrued rewards for a specific account since the last update.
     * @param account_ The address of the account for which rewards will be calculated.
     * @return The amount of rewards accrued since the last update.
     */
    function _calculatePendingBaseRewards(address account_) internal view returns (uint256) {
        uint32 lastUpdateTimestamp = _balances[account_].lastUpdateTimestamp;
        if (lastUpdateTimestamp == 0) return 0;
        return _calculateRewards(_balances[account_].value, lastUpdateTimestamp);
    }

    /**
     * @notice Calculates the current accrued rewards for a specific account since the last update.
     * @param account_ The address of the account for which rewards will be calculated.
     * @return The amount of rewards accrued since the last update.
     */
    function _calculateCurrentStakingRewards(address account_) internal view returns (uint256) {
        uint32 lastUpdateTimestamp = _balances[account_].lastUpdateTimestamp;
        if (lastUpdateTimestamp == 0) return 0;
        return _calculateRewards(_balances[account_].value, lastUpdateTimestamp);
    }

    // TODO: DOC
    function _calculateTotalUserStakingRewards(address account_) internal view returns (uint256) {
        uint256 totalStakingRewards = 0;
        for (uint256 i = 0; i < pools.length; i++) {
            totalStakingRewards += _calculatePoolStakingRewards(i, account_);
        }
        return totalStakingRewards;
    }

    // TODO: DOC
    function _calculatePoolStakingRewards(uint256 poolId, address account_) internal view returns (uint256) {
        UserStake memory stakeInfo = stakes[poolId][account_];
        uint224 lpAmount = stakeInfo.lpBalanceStaked;
        if (lpAmount == 0) return 0;
        if (_balances[account_].lastUpdateTimestamp == 0) return 0;

        uint32 lastUpdateTimestamp = _balances[account_].lastUpdateTimestamp;
        uint256 timeElapsed = block.timestamp - lastUpdateTimestamp;
        if (timeElapsed == 0) return 0;

        if (stakeInfo.lpStakeStartTimestamp == 0) {
            return 0;
        }

        uint256 timeStaked = block.timestamp - stakeInfo.lpStakeStartTimestamp;
        StakingPool memory pool = pools[poolId];

        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(pool.lpToken).getReserves();
        address token0 = IUniswapV2Pair(pool.lpToken).token0();
        uint256 reserve = (token0 == address(this)) ? reserve0 : reserve1;

        if (reserve == 0) {
            return 0;
        }

        uint256 lpTotalSupply = IERC20(pool.lpToken).totalSupply();
        uint256 compotaReserve = (uint256(lpAmount) * reserve) / lpTotalSupply;

        uint256 cubicMultiplier = _calculateCubicMultiplier(pool.multiplierMax, pool.timeThreshold, timeStaked);

        uint256 rewardsStaking = (compotaReserve * yearlyRate * timeElapsed * cubicMultiplier) /
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
     *TODO
     */
    function _calculateGlobalStakingRewards() internal view returns (uint224) {
        uint256 totalStakingRewards = 0;

        for (uint256 i = 0; i < activeStakers.length; i++) {
            address staker = activeStakers[i];

            for (uint256 poolId = 0; poolId < pools.length; poolId++) {
                totalStakingRewards += _calculatePoolStakingRewards(poolId, staker);
            }
        }

        return toSafeUint224(totalStakingRewards);
    }

    /**
     * @notice Generalized function to calculate rewards based on an amount and a timestamp.
     * @param amount_ The amount of tokens to calculate rewards for.
     * @param timestamp_ The timestamp to calculate rewards from.
     * @return The amount of rewards accrued since the last update.
     */
    function _calculateRewards(uint224 amount_, uint256 timestamp_) internal view returns (uint224) {
        if (internalTotalSupply == maxTotalSupply) return 0;
        if (timestamp_ == 0) return 0;
        uint256 timeElapsed;
        // Safe to use unchecked here, since `block.timestamp` is always greater than `_lastUpdateTimestamp[account_]`.
        unchecked {
            timeElapsed = block.timestamp - timestamp_;
        }
        return toSafeUint224((amount_ * timeElapsed * yearlyRate) / (SCALE_FACTOR * uint256(SECONDS_PER_YEAR)));
    }

    /**
     * @dev Reverts if the balance is insufficient.
     * @param caller_ Caller
     * @param amount_ AccountBalance to check.
     */
    function _revertIfInsufficientBalance(address caller_, uint256 amount_) internal view {
        uint224 balance = _balances[caller_].value;
        if (balance < amount_) revert InsufficientBalance(amount_);
    }

    /**
     * @dev Reverts if the amount of a `mint` or `burn` is equal to 0.
     * @param amount_ Amount to check.
     */
    function _revertIfInsufficientAmount(uint256 amount_) internal pure {
        if (amount_ == 0) revert InsufficientAmount(amount_);
    }

    /**
     * @dev Reverts if the recipient of a `mint` or `transfer` is address(0).
     * @param recipient_ Address of the recipient to check.
     */
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
