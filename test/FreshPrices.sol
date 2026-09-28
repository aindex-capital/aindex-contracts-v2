// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFolio} from "folio/interfaces/IFolio.sol";

/// The queued reference bands, approved unchanged as the fresh ones: the market did not move.
function refPrices(IFolio.TokenRebalanceParams[] memory t) pure returns (IFolio.PriceRange[] memory p) {
    p = new IFolio.PriceRange[](t.length);
    for (uint256 i; i < t.length; ++i) p[i] = t[i].price;
}
