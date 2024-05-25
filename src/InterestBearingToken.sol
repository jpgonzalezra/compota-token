// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.26;

import { ERC20 } from "solmate/tokens/ERC20.sol";
import { Owned } from "solmate/auth/Owned.sol";

// import { console } from "forge-std/console.sol";

contract InterestBearingToken is ERC20, Owned {
    /* ============ Events ============ */

    /**
     * @notice Emmited when the account starts earning token
     * @param  account The account that started earning.
     */
    event StartedEarning(address indexed account);

    /* ============ Structs ============ */
    // nothing for now

    /* ============ Errors ============ */
    error InvalidRecipient(address recipient_);
    error InvalidYearlyRate(uint16 rate_);
    error InsufficientAmount(uint256 amount_);

    /* ============ Variables ============ */
    /// @notice The number of seconds in a year.
    uint32 internal constant SECONDS_PER_YEAR = 31_536_000;
    uint16 public constant MIN_YEARLY_RATE = 100; // 1% APY in BPS
    uint16 public constant MAX_YEARLY_RATE = 4000; // 40% APY as max

    uint16 public yearlyRate; // interest rate in BPS beetween 100 (1%) and 40000 (40%)

    mapping(address => uint256) internal lastUpdateTimestamp;
    mapping(address => uint256) internal accruedInterest;

    /* ============ Modifiers ============ */
    // nothing for now

    /* ============ Constructor ============ */
    constructor(uint16 yearlyRate_) ERC20("IBToken", "IB", 6) Owned(msg.sender) {
        setYearlyRate(yearlyRate_);
    }

    function setYearlyRate(uint16 newRate_) public onlyOwner {
        if (newRate_ < MIN_YEARLY_RATE || newRate_ > MAX_YEARLY_RATE) {
            revert InvalidYearlyRate(newRate_);
        }
        yearlyRate = newRate_;
    }

    /* ============ Interactive Functions ============ */
    function mint(address to_, uint256 amount_) external onlyOwner {
        _revertIfInvalidRecipient(to_);
        _revertIfInsufficientAmount(amount_);
        _updateRewards(to_);
        _mint(to_, amount_);
    }

    function burn(uint256 amount_) external {
        _revertIfInsufficientAmount(amount_);
        if (this.balanceOf(msg.sender) < amount_) revert InsufficientAmount(amount_);
        address caller = msg.sender;
        _updateRewards(caller);
        _burn(caller, amount_);
    }

    function updateInterest(address account_) external {
        _updateRewards(account_);
    }

    function totalBalance(address account_) external view returns (uint256) {
        return this.balanceOf(account_) + accruedInterest[account_];
    }

    /* ============ Internal Interactive Functions ============ */

    function _updateRewards(address account_) internal {
        uint256 timestamp = block.timestamp;
        if (lastUpdateTimestamp[account_] == 0) {
            lastUpdateTimestamp[account_] = timestamp;
            emit StartedEarning(account_);
            return;
        }
        // we are calculating always using the raw balance (simple interest)
        uint256 rawBalance = this.balanceOf(account_);

        // Safe to use unchecked here, since `block.timestamp` is always greater than `lastUpdateTimestamp[account_]`.
        unchecked {
            uint256 timeElapsed = timestamp - lastUpdateTimestamp[account_];
            uint256 interest = (rawBalance * timeElapsed * yearlyRate) / (10_000 * uint256(SECONDS_PER_YEAR));
            accruedInterest[account_] += interest;
        }
        lastUpdateTimestamp[account_] = block.timestamp;
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
