// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { ICompota } from "./interfaces/ICompota.sol";

library Helpers {
    /**
     * @notice Casts a given uint256 value to a uint224,
     *         ensuring that it is less than or equal to the maximum uint224 value.
     * @param  value_ The value to check.
     * @return The value casted to uint224.
     * @dev Based on https://github.com/MZero-Labs/common/blob/main/src/libs/UIntMath.sol
     */
    function toSafeUint224(uint256 value_) internal pure returns (uint224) {
        if (value_ > type(uint224).max) revert ICompota.InvalidUInt224();
        return uint224(value_);
    }
}
