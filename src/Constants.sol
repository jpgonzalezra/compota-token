// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

library Constants {
    /// @notice Scale factor used to convert basis points (bps) into decimal fractions.
    uint16 internal constant SCALE_FACTOR = 10_000; // Ex, 100 bps (1%) is converted to 0.01 by dividing by 10,000

    /// @notice The number of seconds in a year.
    uint32 internal constant SECONDS_PER_YEAR = 31_536_000;

    /// @notice The minimum yearly rate of interest in basis points (bps).
    uint16 public constant MIN_YEARLY_RATE = 100; // This represents a 1% annual percentage yield (APY).

    /// @notice The maximum yearly rate of interest in basis points (bps).
    uint16 public constant MAX_YEARLY_RATE = 4_000; // This represents a 40% annual percentage yield (APY).
}
