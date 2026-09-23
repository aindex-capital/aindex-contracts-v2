// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Folio} from "folio/Folio.sol";
import {MonthlyMandate} from "./MonthlyMandate.sol";

/**
 * Holds `MonthlyMandate`'s creation code so the factory does not have to.
 *
 * A contract that deploys another carries the other's whole creation code in its own runtime, and
 * the mandate is large enough to push `IndexFactory` past the 24,576-byte limit. The factory creates
 * one of these in its constructor and asks it for each mandate instead.
 *
 * Stateless and permissionless on purpose. Anyone may deploy a mandate through it, which gives them
 * nothing: a mandate has no power over an index until that index grants it roles, and only the
 * factory's launch path does that.
 */
contract MandateDeployer {
    function deploy(Folio index, MonthlyMandate.Config calldata cfg, MonthlyMandate.TokenRule[] calldata rules)
        external returns (MonthlyMandate)
    {
        return new MonthlyMandate(index, cfg, rules);
    }
}
