// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Separate compilation unit: upstream PoolManager pins 0.8.26; Folio pins 0.8.28.
// Tests deploy its compiled artifact, without modifying either upstream pragma.
import {PoolManager} from "v4-core/src/PoolManager.sol";
