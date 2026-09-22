// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Local valuation fixture only. Anyone can change this feed; never a production price source.
contract MockUsdFeed {
    uint8 public immutable decimals;
    uint80 private roundId;
    int256 private answer;
    uint256 private updatedAt;

    constructor(uint8 decimals_, int256 answer_) {
        decimals = decimals_;
        setAnswer(answer_);
    }

    function setAnswer(int256 value) public {
        answer = value;
        updatedAt = block.timestamp;
        ++roundId;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }
}
