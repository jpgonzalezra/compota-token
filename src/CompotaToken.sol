// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.23;

import { Owned } from "solmate/auth/Owned.sol";
import { ERC20Extended } from "@mzero-labs/ERC20Extended.sol";
import { IERC20 } from "@mzero-labs/interfaces/IERC20.sol";
import { ICompotaToken } from "./intefaces/ICompotaToken.sol";

/**
 * @title CompotaToken
 * @dev ERC20 interest-bearing token that continuously accrues yield to its holders.
 */
contract CompotaToken is ICompotaToken, ERC20Extended, Owned {
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

    uint32 public latestUpdateTimestamp;

    uint224 internal _totalSupply;

    uint224 public maxTotalSupply;

    uint32 public cooldownPeriod;

    address public minter;
    struct Balance {
        // 1st slot
        // @dev This timestamp will work until approximately the year 2106
        uint32 lastUpdateTimestamp;
        uint224 value;
    }

    mapping(address => Balance) internal _balances;
    mapping(address => uint32) internal _latestClaimTimestamp;

    /* ============ Constructor ============ */

    constructor(
        uint16 yearlyRate_,
        uint32 cooldownPeriod_,
        uint224 maxTotalSupply_
    ) ERC20Extended("Compota Token", "COMPOTA", 6) Owned(msg.sender) {
        setYearlyRate(yearlyRate_);
        setCooldownPeriod(cooldownPeriod_);
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
     * @notice Updates the cooldown period required between reward claims.
     * @dev Only the owner can call this function.
     * @param newCooldownPeriod_ The new coolddown period.
     */
    function setCooldownPeriod(uint32 newCooldownPeriod_) public onlyOwner {
        if (newCooldownPeriod_ == 0) {
            revert InvalidCooldownPeriod(newCooldownPeriod_);
        }
        uint32 oldCooldownPeriod_ = cooldownPeriod;
        cooldownPeriod = newCooldownPeriod_;
        emit CooldownPeriodUpdated(oldCooldownPeriod_, newCooldownPeriod_);
    }

    /**
     * @notice Transfers the minter role to a new address.
     * @dev Only the owner of the contract can call this function.
     * @param newMinter_ The address of the new minter.
     */
    function transferMinter(address newMinter_) public onlyOwner {
        address oldMinter = minter;
        minter = newMinter_;
        emit MinterTransferred(oldMinter, newMinter_);
    }

    /**
     * @notice Mints new tokens to a specified address.
     * @dev Only the owner can call this function.
     * @param to_ The address where the new tokens will be sent.
     * @param amount_ The number of tokens to mint.
     */
    function mint(address to_, uint256 amount_) external {
        address sender = msg.sender;
        if (sender != owner && sender != minter) revert Unauthorized();
        _revertIfInvalidRecipient(to_);
        _revertIfInsufficientAmount(amount_);
        _updateRewards(to_);
        _mint(to_, amount_);
    }

    /**
     * @notice Burns tokens from the sender account.
     * @param amount_ The number of tokens to burn.
     */
    function burn(uint256 amount_) external {
        _revertIfInsufficientAmount(amount_);
        address caller = msg.sender;
        _updateRewards(caller);
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
        return _balances[account_].value + _calculateCurrentRewards(account_);
    }

    /**
     * @notice Retrieves the total supply of tokens, including unclaimed rewards.
     * @return totalSupply_ The total supply of tokens, including unclaimed rewards.
     * @inheritdoc IERC20
     */
    function totalSupply() external view returns (uint256 totalSupply_) {
        return uint256(_totalSupply + _calculateTotalCurrentRewards());
    }

    /**
     * @notice Claims the accumulated rewards for the sender.
     * @dev It can only be called by the owner of the rewards.
     */
    function claimRewards() external {
        address caller = msg.sender;
        uint32 currentTimestamp = uint32(block.timestamp);
        uint32 latestClaim = _latestClaimTimestamp[caller];

        if (currentTimestamp - latestClaim < cooldownPeriod) {
            revert CooldownNotCompleted(latestClaim + cooldownPeriod - currentTimestamp);
        }

        _latestClaimTimestamp[caller] = currentTimestamp;

        _updateRewards(caller);
    }

    /* ============ Internal Interactive Functions ============ */

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

        _balances[sender_].value -= safe224(amount_);

        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint224 value.
        unchecked {
            _balances[recipient_].value += safe224(amount_);
        }

        emit Transfer(sender_, recipient_, amount_);
    }

    /**
     * @notice Mints new tokens and assigns them to the specified account.
     * @param to_ The address of the account receiving the newly minted tokens.
     * @param amount_ The amount of tokens to mint.
     */
    function _mint(address to_, uint256 amount_) internal virtual {
        if (_totalSupply + amount_ > maxTotalSupply) {
            amount_ = maxTotalSupply - _totalSupply;
        }

        if (amount_ == 0) {
            return;
        }

        _totalSupply += safe224(amount_);

        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint224 value.
        unchecked {
            _balances[to_].value += safe224(amount_);
        }

        emit Transfer(address(0), to_, amount_);
    }

    /**
     * @notice Burns tokens from the specified account.
     * @param from_ The address of the account from which tokens will be burned.
     * @param amount_ The amount of tokens to burn.
     */
    function _burn(address from_, uint256 amount_) internal virtual {
        _balances[from_].value -= safe224(amount_);

        // Cannot underflow because a user's balance
        // will never be larger than the total supply.
        unchecked {
            _totalSupply -= safe224(amount_);
        }

        emit Transfer(from_, address(0), amount_);
    }

    /**
     * @notice Updates the accrued rewards for the specified account.
     * @param account_ The address of the account for which rewards will be updated.
     */
    function _updateRewards(address account_) internal {
        uint32 timestamp = uint32(block.timestamp);
        latestUpdateTimestamp = timestamp;

        if (_balances[account_].lastUpdateTimestamp == 0) {
            _balances[account_].lastUpdateTimestamp = timestamp;
            _latestClaimTimestamp[account_] = timestamp;
            emit StartedEarningRewards(account_);
            return;
        }

        uint256 rewards = _calculateCurrentRewards(account_);
        if (rewards > 0) {
            _mint(account_, rewards);
        }
        _balances[account_].lastUpdateTimestamp = timestamp;
    }

    /**
     * @notice Calculates the current accrued rewards for a specific account since the last update.
     * @param account_ The address of the account for which rewards will be calculated.
     * @return The amount of rewards accrued since the last update.
     */
    function _calculateCurrentRewards(address account_) internal view returns (uint256) {
        uint32 lastUpdateTimestamp = _balances[account_].lastUpdateTimestamp;
        if (lastUpdateTimestamp == 0) return 0;
        return _calculateRewards(_balances[account_].value, lastUpdateTimestamp);
    }

    /**
     * @notice Calculates the total current accrued rewards for the entire supply since the last update.
     * @return The amount of rewards accrued since the last update.
     */
    function _calculateTotalCurrentRewards() internal view returns (uint224) {
        if (latestUpdateTimestamp == 0) return 0;
        return _calculateRewards(_totalSupply, latestUpdateTimestamp);
    }

    /**
     * @notice Generalized function to calculate rewards based on an amount and a timestamp.
     * @param amount_ The amount of tokens to calculate rewards for.
     * @param timestamp_ The timestamp to calculate rewards from.
     * @return The amount of rewards accrued since the last update.
     */
    function _calculateRewards(uint224 amount_, uint256 timestamp_) internal view returns (uint224) {
        if (_totalSupply == maxTotalSupply) return 0;
        if (timestamp_ == 0) return 0;
        uint256 timeElapsed;
        // Safe to use unchecked here, since `block.timestamp` is always greater than `_lastUpdateTimestamp[account_]`.
        unchecked {
            timeElapsed = block.timestamp - timestamp_;
        }
        return safe224((amount_ * timeElapsed * yearlyRate) / (SCALE_FACTOR * uint256(SECONDS_PER_YEAR)));
    }

    /**
     * @dev Reverts if the balance is insufficient.
     * @param caller_ Caller
     * @param amount_ Balance to check.
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
    function safe224(uint256 n) internal pure returns (uint224) {
        if (n > type(uint224).max) revert InvalidUInt224();
        return uint224(n);
    }
}
