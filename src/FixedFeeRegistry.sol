// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Immutable fee policy implementing Folio's registry interface; never custodies funds.
///
/// @dev    Folio computes `daoFeeShares = totalFeeShares * protocolPortion / 1e18`, so with the
///         factory's 135 bps mint fee a `protocolPortion` of 35/135 gives the protocol exactly
///         35 bps and the creator the other 100. `PROTOCOL_PORTION_FOR_35BPS` below is that
///         value, named because a bare 259259259259259259 in a deploy script is unreadable and
///         the number it has to agree with lives in another file.
///
///         Folio additionally enforces its own 3 bps minimum mint fee even if floor is zero.
/// @notice The split that turns the factory's 135 bps mint fee into 35 bps of protocol revenue.
/// @dev    A library, because this number has to agree with `IndexFactoryBase.mintFee` and a
///         deploy script has to pass it. A bare 259259259259259259 in three places is how those
///         three drift apart.
library MintSplit {
    /// @notice 35/135 in D18. Use with a `mintFee` of 0.0135e18 and nothing else.
    uint256 internal constant PROTOCOL_PORTION_FOR_35BPS = 259_259_259_259_259_259;
}

contract FixedFeeRegistry {
    address public immutable recipient;
    uint256 public immutable protocolPortion;
    uint256 public immutable feeFloor;
    error InvalidConfiguration();

    constructor(address recipient_, uint256 protocolPortion_, uint256 feeFloor_) {
        if (recipient_ == address(0) || protocolPortion_ > 1e18 || feeFloor_ > 0.001e18) revert InvalidConfiguration();
        recipient = recipient_;
        protocolPortion = protocolPortion_;
        feeFloor = feeFloor_;
    }

    function getFeeDetails(address) external view returns (address, uint256, uint256, uint256) {
        return (recipient, protocolPortion, 1e18, feeFloor);
    }
}
