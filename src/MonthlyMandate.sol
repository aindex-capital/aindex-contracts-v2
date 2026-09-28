// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Folio} from "folio/Folio.sol";
import {IFolio} from "folio/interfaces/IFolio.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Manual mandate with notice, price approval and one auction per cycle, over a token universe
///         that grows only by announcement.
/// @dev Bounds are raw-token quantities per basket unit, NOT percentage-of-NAV guarantees.
/// The reviewer is trusted to assess current prices; this is not an autonomous oracle policy.
///
/// **v3: prices are set when the auction starts, not when it is queued.** A queued proposal commits to
/// weights and to reference prices. Hours or days later, when the reviewer approves, the reviewer
/// supplies fresh price bands, and `execute` opens the auction on those. Each fresh band must be
/// no wider than `maxPriceSpreadBps` and stay within `MAX_REPRICE_BPS` of the queued reference, so
/// the reviewer can follow the market but cannot invent it. The approval lasts at most five minutes,
/// so an auction never runs on prices more than minutes old.
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

    /// @notice Read by tooling to tell a v3 mandate (fresh prices at approval) from v2, which has no such getter.
    uint256 public constant MANDATE_VERSION = 3;
    /// @notice How far a fresh band may sit from the queued reference: 15%, either way, per token.
    uint256 public constant MAX_REPRICE_BPS = 1500;
    /// The proposal the fresh prices were approved for, and the prices, in token order.
    bytes32 public approvedHash;
    IFolio.PriceRange[] private _approvedPrices;

    /**
     * Adding a token to what the index may hold.
     *
     * The universe is not frozen at launch: a creator who cannot add next month's token has an
     * index that ages. It grows only by announcement. A new token, with its limits, is announced
     * and waits at least a week (longer if the index's own notice is longer) before any rebalance
     * can use it, so holders see it coming and can redeem for free first. Any role holder can
     * cancel an announcement. Removing needs no ceremony: a rebalance to weight zero sells a token
     * out, Folio drops it from the basket, and `retireToken` then frees its slot.
     */
    struct PendingToken {
        TokenRule rule;
        uint256 readyAt;
    }

    uint256 public constant MAX_TOKENS = 16;
    uint256 public constant MIN_ADDITION_NOTICE = 7 days;
    PendingToken[] private _pendingTokens;

    error Unauthorized();
    error InvalidPolicy();
    error InvalidProposal();
    error WrongState();
    error TooEarly();
    error ApprovalExpired();

    event ProposalQueued(bytes32 indexed hash, uint256 indexed nonce, uint256 readyAt, uint256 expiresAt,
        IFolio.TokenRebalanceParams[] tokens);
    event ProposalApproved(bytes32 indexed hash, uint256 until);
    event PricesApproved(bytes32 indexed hash, IFolio.PriceRange[] prices);
    event ProposalExecuted(bytes32 indexed hash, uint256 indexed auctionId, uint256 indexed rebalanceNonce);
    event Cancelled(bytes32 indexed pendingHash, uint256 activeAuctionPlusOne);
    event RoleChangeRequested(uint8 indexed role, uint256 indexed nonce, address indexed replacement,
        address requestedBy, uint256 authorityVersion, uint256 expiresAt);
    event RoleChangeConfirmed(uint8 indexed role, uint256 indexed nonce, uint256 readyAt, uint256 expiresAt);
    event RoleChangeCancelled(uint8 indexed role, uint256 indexed nonce);
    event RoleChanged(uint8 indexed role, uint256 indexed nonce, address indexed replacement,
        address previous, uint256 authorityVersion);
    event TokenAnnounced(address indexed token, uint256 readyAt, uint256 maxWeight, uint256 maxTradeAmount);
    event TokenAnnouncementCancelled(address indexed token);
    event TokenAdded(address indexed token);
    event TokenRetired(address indexed token);

    constructor(Folio index_, Config memory cfg, TokenRule[] memory tokenRules) {
        /*
         * One wallet may hold every role: a creator can run an index alone. What an independent
         * reviewer would have added is a second pair of eyes on prices; without one, holders get
         * time instead. A self-reviewed rebalance must be announced a full day ahead, and
         * redemption is always free, so anyone who dislikes it can leave before it executes.
         */
        if (address(index_).code.length == 0 || cfg.proposer == address(0) || cfg.reviewer == address(0)
            || cfg.guardian == address(0) || cfg.notice < 1 hours
            || (cfg.reviewer == cfg.proposer && cfg.notice < SELF_REVIEW_NOTICE)
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

    /// @notice The shortest notice allowed when the proposer also approves prices.
    uint256 public constant SELF_REVIEW_NOTICE = 24 hours;

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
        _clearApproval();
        emit ProposalQueued(pending, proposalNonce, readyAt, expiry, tokens);
    }

    /// @notice Reviewer approves the queued proposal with fresh price bands, shortly before execution.
    /// @param tokens The proposal exactly as queued: it is checked against the commitment.
    /// @param prices One fresh band per token, in the proposal's order. Each is no wider than
    ///        `maxPriceSpreadBps` and within `MAX_REPRICE_BPS` of that token's queued reference band.
    /// @dev   Calling again before execution replaces both the prices and the window.
    function approve(IFolio.TokenRebalanceParams[] calldata tokens, IFolio.PriceRange[] calldata prices, uint256 until)
        external
    {
        if (msg.sender != config.reviewer) revert Unauthorized();
        bytes32 hash = pending;
        if (hash == bytes32(0) || proposalHash(tokens, proposalNonce, expiresAt) != hash || block.timestamp < readyAt) {
            revert WrongState();
        }
        if (until <= block.timestamp || until > block.timestamp + 5 minutes || until > expiresAt) revert InvalidProposal();
        if (prices.length != tokens.length) revert InvalidProposal();
        delete _approvedPrices;
        for (uint256 i; i < prices.length; ++i) {
            _checkFresh(prices[i], tokens[i].price);
            _approvedPrices.push(prices[i]);
        }
        approvedHash = hash;
        approvedUntil = until;
        emit ProposalApproved(hash, until);
        emit PricesApproved(hash, prices);
    }

    /// A fresh band obeys the same width rule as a queued one, and stays near the queued reference.
    function _checkFresh(IFolio.PriceRange calldata p, IFolio.PriceRange calldata ref) private view {
        if (p.low == 0 || p.high <= p.low || p.high > 1e45
            || p.high - p.low > p.low * config.maxPriceSpreadBps / 10_000
            || p.low < ref.low * (10_000 - MAX_REPRICE_BPS) / 10_000
            || p.high > ref.high * (10_000 + MAX_REPRICE_BPS) / 10_000) revert InvalidProposal();
    }

    /// @notice The fresh bands the current approval will open the auction with; empty when none.
    function approvedPrices() external view returns (IFolio.PriceRange[] memory) {
        return _approvedPrices;
    }

    function execute(IFolio.TokenRebalanceParams[] calldata tokens) external nonReentrant returns (uint256 auctionId) {
        if (!activated || pending == bytes32(0) || proposalHash(tokens, proposalNonce, expiresAt) != pending) revert WrongState();
        if (block.timestamp < readyAt || block.timestamp < nextExecutionAt) revert TooEarly();
        if (block.timestamp > expiresAt || approvedUntil == 0 || block.timestamp > approvedUntil) revert ApprovalExpired();
        bytes32 hash = pending;
        // Belt and braces: every path that changes `pending` also clears the approval, so this cannot
        // fire today. It keeps an approval bound to its proposal if a later change forgets to.
        if (approvedHash != hash || _approvedPrices.length != tokens.length) revert ApprovalExpired();
        _checkRoles();
        _validate(tokens);
        // The auction runs on the fresh bands approved minutes ago, never on the queued reference.
        IFolio.TokenRebalanceParams[] memory fresh = tokens;
        address[] memory assets = new address[](tokens.length);
        IFolio.WeightRange[] memory weights = new IFolio.WeightRange[](tokens.length);
        IFolio.PriceRange[] memory prices = new IFolio.PriceRange[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            fresh[i].price = _approvedPrices[i];
            assets[i] = tokens[i].token;
            weights[i] = tokens[i].weight;
            prices[i] = _approvedPrices[i];
        }
        _clearApproval();
        pending = bytes32(0);
        nextExecutionAt = block.timestamp + config.interval;
        uint256 nonce = index.getRebalanceNonce() + 1;
        IFolio.RebalanceLimits memory limits = IFolio.RebalanceLimits(1e18, 1e18, 1e18);
        uint256 ttl = config.auctionLength + 31;
        index.startRebalance(nonce, fresh, limits, ttl, ttl, block.timestamp);
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
        _clearApproval();
        readyAt = 0;
        expiresAt = 0;
        if (activeAuctionPlusOne != 0) {
            index.closeAuction(activeAuctionPlusOne - 1);
            activeAuctionPlusOne = 0;
        }
    }

    /* -------------------------------------------------------------- the token universe */

    function additionDelay() public view returns (uint256) {
        return config.notice > MIN_ADDITION_NOTICE ? config.notice : MIN_ADDITION_NOTICE;
    }

    function pendingTokens() external view returns (PendingToken[] memory) {
        return _pendingTokens;
    }

    /// @notice Announce a token the index may hold from `additionDelay()` from now. Proposer only.
    /// @dev    A new token starts with no floor (`minWeight` 0): adding it never forces a purchase.
    function announceToken(TokenRule calldata r) external {
        if (msg.sender != config.proposer) revert Unauthorized();
        if (!activated) revert WrongState();
        if (rules.length + _pendingTokens.length >= MAX_TOKENS || r.token.code.length == 0
            || r.token == address(index) || r.token == address(this) || r.minWeight != 0 || r.maxWeight == 0
            || r.maxWeight > 1e54 || r.maxTradeAmount == 0 || _ruleIndex(r.token) != type(uint256).max
            || _pendingIndex(r.token) != type(uint256).max) revert InvalidPolicy();
        uint256 ready = block.timestamp + additionDelay();
        _pendingTokens.push(PendingToken(r, ready));
        emit TokenAnnounced(r.token, ready, r.maxWeight, r.maxTradeAmount);
    }

    /// @notice Withdraw an announcement before it is added. Any role holder.
    function cancelToken(address token) external {
        if (msg.sender != config.proposer && msg.sender != config.reviewer && msg.sender != config.guardian) revert Unauthorized();
        uint256 i = _pendingIndex(token);
        if (i == type(uint256).max) revert WrongState();
        _removePending(i);
        emit TokenAnnouncementCancelled(token);
    }

    /// @notice Make an announced token part of the universe once its wait is over. Proposer only.
    /// @dev    Only between rebalances: a proposal commits to the exact token list it was queued with.
    function addToken(address token) external {
        if (msg.sender != config.proposer) revert Unauthorized();
        _checkQuiet();
        uint256 i = _pendingIndex(token);
        if (i == type(uint256).max) revert WrongState();
        if (block.timestamp < _pendingTokens[i].readyAt) revert TooEarly();
        rules.push(_pendingTokens[i].rule);
        _removePending(i);
        emit TokenAdded(token);
    }

    /// @notice Drop a token the index no longer holds from its universe, freeing a slot. Proposer only.
    /// @dev    Only once Folio has removed it from the basket, which happens when a rebalance sells it
    ///         out. The universe never falls below two tokens.
    function retireToken(address token) external {
        if (msg.sender != config.proposer) revert Unauthorized();
        _checkQuiet();
        uint256 i = _ruleIndex(token);
        if (i == type(uint256).max || rules.length <= 2) revert InvalidPolicy();
        (address[] memory held,) = index.totalAssets();
        for (uint256 j; j < held.length; ++j) if (held[j] == token) revert WrongState();
        rules[i] = rules[rules.length - 1];
        rules.pop();
        emit TokenRetired(token);
    }

    function _checkQuiet() private view {
        if (!activated || pending != bytes32(0)) revert WrongState();
        if (activeAuctionPlusOne != 0) {
            (,, uint256 endTime) = index.auctions(activeAuctionPlusOne - 1);
            if (block.timestamp <= endTime) revert WrongState();
        }
    }

    function _ruleIndex(address token) private view returns (uint256) {
        for (uint256 i; i < rules.length; ++i) if (rules[i].token == token) return i;
        return type(uint256).max;
    }

    function _pendingIndex(address token) private view returns (uint256) {
        for (uint256 i; i < _pendingTokens.length; ++i) if (_pendingTokens[i].rule.token == token) return i;
        return type(uint256).max;
    }

    function _removePending(uint256 i) private {
        _pendingTokens[i] = _pendingTokens[_pendingTokens.length - 1];
        _pendingTokens.pop();
    }

    function clearExpired() external {
        if (pending == bytes32(0) || block.timestamp <= expiresAt) revert WrongState();
        emit Cancelled(pending, 0);
        pending = bytes32(0);
        _clearApproval();
    }

    function _clearApproval() private {
        approvedUntil = 0;
        approvedHash = bytes32(0);
        delete _approvedPrices;
    }
}
