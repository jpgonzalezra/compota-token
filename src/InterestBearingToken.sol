// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.23;

import { Owned } from "solmate/auth/Owned.sol";
import { ERC20Extended } from "@mzero-labs/ERC20Extended.sol";
import { IERC20 } from "@mzero-labs/interfaces/IERC20.sol";

/**
 * @title InterestBearingToken
 * @dev ERC20 token that accrues interest over time.
 */
contract InterestBearingToken is ERC20Extended, Owned {
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
     * @notice Emitted when rewards are claimed by an account.
     * @param account The account that claimed the rewards.
     * @param rewards The amount of rewards claimed.
     */
    event RewardsClaimed(address indexed account, uint256 rewards);

    /* ============ Structs ============ */
    // nothing for now

    /* ============ Custom Errors ============ */

    /// @notice Error thrown when the yearly rate is invalid.
    error InvalidYearlyRate(uint16 rate);

    /// @notice Error thrown when the balance is insufficient for a specific operation.
    error InsufficientBalance(uint256 amount);

    /* ============ Variables ============ */
    /// @notice The number of seconds in a year.
    uint32 internal constant SECONDS_PER_YEAR = 31_536_000;

    ///@notice The minimum yearly rate of interest in basis points (BPS).
    uint16 public constant MIN_YEARLY_RATE = 100; // This represents a 1% annual percentage yield (APY).

    ///@notice The maximum yearly rate of interest in basis points (BPS).
    uint16 public constant MAX_YEARLY_RATE = 4000; // This represents a 40% annual percentage yield (APY).

    uint256 internal _totalSupply;
    uint256 public unclaimedRewards;
    uint16 public yearlyRate;

    mapping(address => uint256) internal _balances;
    mapping(address => uint256) internal _lastUpdateTimestamp;
    mapping(address => uint256) internal _accruedRewards;

    /* ============ Modifiers ============ */
    // nothing for now

    /* ============ Constructor ============ */

    constructor(uint16 yearlyRate_) ERC20Extended("IBToken", "IB", 6) Owned(msg.sender) {
        setYearlyRate(yearlyRate_);
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
     * @notice Mints new tokens to a specified address.
     * @dev Only the owner can call this function.
     * @param to_ The address where the new tokens will be sent.
     * @param amount_ The number of tokens to mint.
     */
    function mint(address to_, uint256 amount_) external onlyOwner {
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
        _claimRewards(caller);
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
        unchecked {
            return _balances[account_] + _accruedRewards[account_] + _calculateCurrentRewards(account_);
        }
    }

    /// @inheritdoc IERC20
    function totalSupply() external view returns (uint256 totalSupply_) {
        unchecked {
            return _totalSupply + unclaimedRewards;
        }
    }

    function updateRewards(address account) external {
        _updateRewards(account);
    }

    function claimRewards() external {
        _claimRewards(msg.sender);
    }

    /* ============ Internal Interactive Functions ============ */

    function _transfer(address sender_, address recipient_, uint256 amount_) internal override {
        _revertIfInvalidRecipient(recipient_);

        // Claim rewards for both sender and recipient
        _claimRewards(sender_);
        _claimRewards(recipient_);

        _balances[sender_] -= amount_;

        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint256 value.
        unchecked {
            _balances[recipient_] += amount_;
        }

        emit Transfer(sender_, recipient_, amount_);
    }

    function _calculateCurrentRewards(address account_) internal view returns (uint256) {
        if (_lastUpdateTimestamp[account_] == 0) return 0;
        uint256 timeElapsed = block.timestamp - _lastUpdateTimestamp[account_];
        uint256 rawBalance = _balances[account_];
        return (rawBalance * timeElapsed * yearlyRate) / (10_000 * uint256(SECONDS_PER_YEAR));
    }

    function _claimRewards(address caller) public {
        _updateRewards(caller);
        uint256 rewards = _accruedRewards[caller];
        if (rewards > 0) {
            _accruedRewards[caller] = 0;
            unchecked {
                unclaimedRewards -= rewards;
            }
            _mint(caller, rewards);
            emit RewardsClaimed(caller, rewards);
        }
    }

    function _mint(address to, uint256 amount) internal virtual {
        _totalSupply += amount;

        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint256 value.
        unchecked {
            _balances[to] += amount;
        }

        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal virtual {
        _balances[from] -= amount;

        // Cannot underflow because a user's balance
        // will never be larger than the total supply.
        unchecked {
            _totalSupply -= amount;
        }

        emit Transfer(from, address(0), amount);
    }

    function _updateRewards(address account_) internal {
        uint256 timestamp = block.timestamp;
        if (_lastUpdateTimestamp[account_] == 0) {
            _lastUpdateTimestamp[account_] = timestamp;
            emit StartedEarningRewards(account_);
            return;
        }

        // the rewards calculation is using the raw balance
        uint256 rawBalance = _balances[account_];

        // Safe to use unchecked here, since `block.timestamp` is always greater than `_lastUpdateTimestamp[account_]`.
        unchecked {
            uint256 timeElapsed = timestamp - _lastUpdateTimestamp[account_];
            uint256 rewards = (rawBalance * timeElapsed * yearlyRate) / (10_000 * uint256(SECONDS_PER_YEAR));
            _accruedRewards[account_] += rewards;
            unclaimedRewards += rewards;
        }
        _lastUpdateTimestamp[account_] = block.timestamp;
    }

    /**
     * @dev   Reverts if the balance is insufficient.
     * @param caller_ Caller
     * @param amount_ Balance to check.
     */
    function _revertIfInsufficientBalance(address caller_, uint256 amount_) internal view {
        uint256 balance = _balances[caller_];
        if (balance < amount_) revert InsufficientBalance(amount_);
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
