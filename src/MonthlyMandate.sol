// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Folio} from "folio/Folio.sol";
import {IFolio} from "folio/interfaces/IFolio.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Fixed-universe manual mandate with notice, independent price approval and one auction per cycle.
/// @dev Bounds are raw-token quantities per basket unit, NOT percentage-of-NAV guarantees.
/// The reviewer is trusted to assess current prices; this is not an autonomous oracle policy.
/// No arbitrary calls, engine role grants, withdrawals, fee changes or upgrades are exposed.
contract MonthlyMandate is ReentrancyGuard {
    bytes32 private constant MANAGER_ROLE = keccak256("REBALANCE_MANAGER");
    bytes32 private constant LAUNCHER_ROLE = keccak256("AUCTION_LAUNCHER");

    struct TokenRule {
        address token;
        uint256 minWeight;
        uint256 maxWeight;
        uint256 maxTradeAmount;
    }

    struct Config {
        address proposer;
        address reviewer;
        address guardian;
        uint256 notice;
        uint256 interval;
        uint256 auctionLength;
        uint256 maxPriceSpreadBps;
        bytes32 methodologyHash;
    }

    // Role ids: 0 proposer, 1 reviewer, 2 guardian. Both OTHER holders must authorize replacement.
    struct RoleChange {
        address replacement;
        address requestedBy;
        uint256 nonce;
        uint256 version;
        uint256 readyAt;
        uint256 expiresAt;
    }

    Folio public immutable index;
    Config public config;
    TokenRule[] public rules;
    bool public activated;
    bytes32 public pending;
    uint256 public readyAt;
    uint256 public expiresAt;
    uint256 public approvedUntil;
    uint256 public nextExecutionAt;
    uint256 public proposalNonce;
    uint256 public activeAuctionPlusOne;
    uint256 public authorityVersion = 1;
    uint256 public roleChangeNonce;
    mapping(uint8 => RoleChange) public roleChanges;

    error Unauthorized();
    error InvalidPolicy();
    error InvalidProposal();
    error WrongState();
    error TooEarly();
    error ApprovalExpired();

    event ProposalQueued(bytes32 indexed hash, uint256 indexed nonce, uint256 readyAt, uint256 expiresAt,
        IFolio.TokenRebalanceParams[] tokens);
    event ProposalApproved(bytes32 indexed hash, uint256 until);
    event ProposalExecuted(bytes32 indexed hash, uint256 indexed auctionId, uint256 indexed rebalanceNonce);
    event Cancelled(bytes32 indexed pendingHash, uint256 activeAuctionPlusOne);
    event RoleChangeRequested(uint8 indexed role, uint256 indexed nonce, address indexed replacement,
        address requestedBy, uint256 authorityVersion, uint256 expiresAt);
    event RoleChangeConfirmed(uint8 indexed role, uint256 indexed nonce, uint256 readyAt, uint256 expiresAt);
    event RoleChangeCancelled(uint8 indexed role, uint256 indexed nonce);
    event RoleChanged(uint8 indexed role, uint256 indexed nonce, address indexed replacement,
        address previous, uint256 authorityVersion);

    constructor(Folio index_, Config memory cfg, TokenRule[] memory tokenRules) {
        if (address(index_).code.length == 0 || cfg.proposer == address(0) || cfg.reviewer == address(0)
            || cfg.guardian == address(0) || cfg.proposer == cfg.reviewer
            || cfg.guardian == cfg.proposer || cfg.guardian == cfg.reviewer || cfg.notice < 1 hours
            || cfg.interval < 28 days || cfg.auctionLength < 120 || cfg.auctionLength > 1 hours
            || cfg.maxPriceSpreadBps == 0 || cfg.maxPriceSpreadBps > 500
            || cfg.methodologyHash == bytes32(0) || tokenRules.length < 2 || tokenRules.length > 16) revert InvalidPolicy();
        index = index_;
        config = cfg;
        for (uint256 i; i < tokenRules.length; ++i) {
            TokenRule memory r = tokenRules[i];
            if (r.token.code.length == 0 || r.token == address(index_) || r.maxWeight == 0
                || r.minWeight > r.maxWeight || r.maxWeight > 1e54 || r.maxTradeAmount == 0) revert InvalidPolicy();
            for (uint256 j; j < i; ++j) if (tokenRules[j].token == r.token) revert InvalidPolicy();
            rules.push(r);
        }
    }

    /// @dev Called after atomic role handoff. Verifies there is no bypass role left on the engine.
    function activate() external {
        if (activated) revert WrongState();
        _checkRoles();
        (bool weightControl, IFolio.PriceControl priceControl) = index.rebalanceControl();
        if (weightControl || priceControl != IFolio.PriceControl.NONE || index.trustedFillerEnabled()
            || !index.bidsEnabled() || index.maxAuctionLength() != config.auctionLength) revert InvalidPolicy();
        (address[] memory assets,) = index.totalAssets();
        if (assets.length != rules.length) revert InvalidPolicy();
        for (uint256 i; i < assets.length; ++i) if (assets[i] != rules[i].token) revert InvalidPolicy();
        activated = true;
    }

    function _checkRoles() private view {
        if (index.getRoleMemberCount(bytes32(0)) != 1 || !index.hasRole(bytes32(0), address(this))
            || index.getRoleMemberCount(MANAGER_ROLE) != 1 || !index.hasRole(MANAGER_ROLE, address(this))
            || index.getRoleMemberCount(LAUNCHER_ROLE) != 1 || !index.hasRole(LAUNCHER_ROLE, address(this))) revert InvalidPolicy();
    }

    function ruleCount() external view returns (uint256) { return rules.length; }

    function roleChangeDelay() public view returns (uint256) {
        return config.notice > 7 days ? config.notice : 7 days;
    }

    function _holder(uint8 role) private view returns (address) {
        if (role == 0) return config.proposer;
        if (role == 1) return config.reviewer;
        if (role == 2) return config.guardian;
        revert InvalidPolicy();
    }

    function _checkRecoveryAuthority(uint8 role) private view {
        if (msg.sender == _holder(role) || (msg.sender != config.proposer
            && msg.sender != config.reviewer && msg.sender != config.guardian)) revert Unauthorized();
    }

    /// @notice One surviving holder requests; the other confirms. Replacing a request resets all approvals.
    function requestRoleChange(uint8 role, address replacement) external {
        _checkRecoveryAuthority(role);
        if (!activated || replacement == address(0) || replacement == config.proposer
            || replacement == config.reviewer || replacement == config.guardian
            || replacement == address(this) || replacement == address(index)) revert InvalidPolicy();
        uint256 nonce = ++roleChangeNonce;
        roleChanges[role] = RoleChange(replacement, msg.sender, nonce, authorityVersion, 0, block.timestamp + 7 days);
        emit RoleChangeRequested(role, nonce, replacement, msg.sender, authorityVersion, block.timestamp + 7 days);
    }

    function _currentChange(uint8 role, uint256 nonce) private view returns (RoleChange storage change) {
        change = roleChanges[role];
        if (change.replacement == address(0) || change.nonce != nonce || change.version != authorityVersion
            || block.timestamp > change.expiresAt) revert WrongState();
    }

    /// @notice Investor notice starts only after both surviving holders agree to this exact request.
    function confirmRoleChange(uint8 role, uint256 nonce) external {
        _checkRecoveryAuthority(role);
        RoleChange storage change = _currentChange(role, nonce);
        if (msg.sender == change.requestedBy) revert Unauthorized();
        if (change.readyAt != 0) revert WrongState();
        change.readyAt = block.timestamp + roleChangeDelay();
        change.expiresAt = change.readyAt + 7 days;
        emit RoleChangeConfirmed(role, nonce, change.readyAt, change.expiresAt);
    }

    /// @notice Either authorizing holder can withdraw consent; the holder being replaced cannot veto recovery.
    function cancelRoleChange(uint8 role, uint256 nonce) external {
        _checkRecoveryAuthority(role);
        _currentChange(role, nonce);
        delete roleChanges[role];
        emit RoleChangeCancelled(role, nonce);
    }

    /// @notice The replacement wallet accepts after notice. All other requests and old proposals become invalid.
    function acceptRoleChange(uint8 role, uint256 nonce) external nonReentrant {
        RoleChange memory change = _currentChange(role, nonce);
        if (msg.sender != change.replacement) revert Unauthorized();
        if (change.readyAt == 0 || block.timestamp < change.readyAt) revert TooEarly();
        _checkRoles();
        address previous = _holder(role);
        _cancelExecution();
        if (role == 0) config.proposer = change.replacement;
        else if (role == 1) config.reviewer = change.replacement;
        else config.guardian = change.replacement;
        ++authorityVersion;
        delete roleChanges[role];
        emit RoleChanged(role, nonce, change.replacement, previous, authorityVersion);
    }

    function proposalHash(IFolio.TokenRebalanceParams[] calldata tokens, uint256 nonce, uint256 expiry)
        public view returns (bytes32)
    {
        return keccak256(abi.encode(block.chainid, address(this), address(index), config.methodologyHash,
            authorityVersion, nonce, expiry, tokens));
    }

    function queue(IFolio.TokenRebalanceParams[] calldata tokens, uint256 expiry) external {
        if (msg.sender != config.proposer) revert Unauthorized();
        if (!activated || pending != bytes32(0)) revert WrongState();
        if (expiry < block.timestamp + config.notice + 60 || expiry > block.timestamp + config.notice + 7 days) {
            revert InvalidProposal();
        }
        _validate(tokens);
        pending = proposalHash(tokens, ++proposalNonce, expiry);
        readyAt = block.timestamp + config.notice;
        expiresAt = expiry;
        approvedUntil = 0;
        emit ProposalQueued(pending, proposalNonce, readyAt, expiry, tokens);
    }

    /// @notice Reviewer attests to current executable price bounds shortly before execution.
    function approve(bytes32 hash, uint256 until) external {
        if (msg.sender != config.reviewer) revert Unauthorized();
        if (hash == bytes32(0) || hash != pending || block.timestamp < readyAt) revert WrongState();
        if (until <= block.timestamp || until > block.timestamp + 5 minutes || until > expiresAt) revert InvalidProposal();
        approvedUntil = until;
        emit ProposalApproved(hash, until);
    }

    function execute(IFolio.TokenRebalanceParams[] calldata tokens) external nonReentrant returns (uint256 auctionId) {
        if (!activated || pending == bytes32(0) || proposalHash(tokens, proposalNonce, expiresAt) != pending) revert WrongState();
        if (block.timestamp < readyAt || block.timestamp < nextExecutionAt) revert TooEarly();
        if (block.timestamp > expiresAt || approvedUntil == 0 || block.timestamp > approvedUntil) revert ApprovalExpired();
        _checkRoles();
        _validate(tokens);
        bytes32 hash = pending;
        pending = bytes32(0);
        approvedUntil = 0;
        nextExecutionAt = block.timestamp + config.interval;
        uint256 nonce = index.getRebalanceNonce() + 1;
        IFolio.RebalanceLimits memory limits = IFolio.RebalanceLimits(1e18, 1e18, 1e18);
        uint256 ttl = config.auctionLength + 31;
        index.startRebalance(nonce, tokens, limits, ttl, ttl, block.timestamp);
        address[] memory assets = new address[](tokens.length);
        IFolio.WeightRange[] memory weights = new IFolio.WeightRange[](tokens.length);
        IFolio.PriceRange[] memory prices = new IFolio.PriceRange[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            assets[i] = tokens[i].token;
            weights[i] = tokens[i].weight;
            prices[i] = tokens[i].price;
        }
        auctionId = index.openAuction(nonce, assets, weights, prices, limits, config.auctionLength);
        // Ending a rebalance blocks further auctions but leaves this auction open until its deadline.
        // Thus Folio's per-auction volume cap cannot be multiplied by opening another auction.
        index.endRebalance(nonce);
        activeAuctionPlusOne = auctionId + 1;
        emit ProposalExecuted(hash, auctionId, nonce);
    }

    function _validate(IFolio.TokenRebalanceParams[] calldata tokens) private view {
        if (tokens.length != rules.length) revert InvalidProposal();
        for (uint256 i; i < tokens.length; ++i) {
            IFolio.TokenRebalanceParams calldata t = tokens[i];
            TokenRule storage r = rules[i];
            if (t.token != r.token || !t.inRebalance || t.weight.low != t.weight.spot
                || t.weight.spot != t.weight.high || t.weight.low < r.minWeight || t.weight.high > r.maxWeight
                || t.maxAuctionSize == 0 || t.maxAuctionSize > r.maxTradeAmount
                || t.price.low == 0 || t.price.high <= t.price.low || t.price.high > 1e45
                || t.price.high - t.price.low > t.price.low * config.maxPriceSpreadBps / 10_000) revert InvalidProposal();
        }
    }

    /// @notice Cancellation never refunds the consumed monthly execution budget.
    function cancel() external nonReentrant {
        if (msg.sender != config.guardian && msg.sender != config.reviewer) revert Unauthorized();
        _cancelExecution();
    }

    function _cancelExecution() private {
        emit Cancelled(pending, activeAuctionPlusOne);
        pending = bytes32(0);
        approvedUntil = 0;
        readyAt = 0;
        expiresAt = 0;
        if (activeAuctionPlusOne != 0) {
            index.closeAuction(activeAuctionPlusOne - 1);
            activeAuctionPlusOne = 0;
        }
    }

    function clearExpired() external {
        if (pending == bytes32(0) || block.timestamp <= expiresAt) revert WrongState();
        emit Cancelled(pending, 0);
        pending = bytes32(0);
        approvedUntil = 0;
    }
}
