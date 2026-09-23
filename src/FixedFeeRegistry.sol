// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The split of every Folio fee: the 0.50% mint fee, and the yearly fee, which is zero.
///
/// @dev    Folio computes `daoFeeShares = totalFeeShares * protocolPortion / 1e18`, then gives
///         `folioFeeForSelf` of what is left to holders (those shares are never minted to anyone,
///         so backing per share rises) and the rest to the creator. With a 50 bps mint fee:
///
///             protocol   50 x 0.40         = 20 bps
///             holders    50 x 0.60 x 0.50  = 15 bps
///             creator    50 x 0.60 x 0.50  = 15 bps
///
///         A library, because these numbers have to agree with `IndexFactoryBase` and a deploy
///         script has to pass one of them. A bare 400000000000000000 in three places is how those
///         three drift apart. Folio additionally enforces its own 3 bps minimum protocol share.
///
///         The registry's floor must stay zero. Folio raises the yearly fee to the floor even when
///         the index sets it to zero, so a nonzero floor would bring back a fee on holding.
library MintSplit {
    /// @notice The protocol's portion of every Folio fee, D18.
    uint256 internal constant PROTOCOL_PORTION = 0.4e18;
    /// @notice The holders' portion of what the protocol leaves, D18; Folio's `folioFeeForSelf`.
    uint256 internal constant HOLDER_PORTION = 0.5e18;
    /// @notice The mint fee, D18.
    uint256 internal constant MINT_FEE = 0.005e18;
}

/// @notice Immutable fee policy implementing Folio's registry interface; never custodies funds.
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
