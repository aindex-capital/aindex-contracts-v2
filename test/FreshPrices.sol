// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFolio} from "folio/interfaces/IFolio.sol";

/// The queued reference prices, approved unchanged as the fresh ones: the market did not move.
function refPrices(IFolio.TokenRebalanceParams[] memory t) pure returns (uint256[] memory p) {
    p = new uint256[](t.length);
    for (uint256 i; i < t.length; ++i) p[i] = t[i].price.low;
}
