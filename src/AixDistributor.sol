// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @notice Pays $AIX holders their share of the daily payout, in one ERC-20 (AINDEX Strategy shares).
/// @dev A cumulative Merkle distributor. Each day the poster (the payout wallet) buys shares, sends them
/// here and posts a new root. A leaf says what an account is owed in total since the first day, so a
/// root replaces the previous one and nothing expires when a new day is posted. `claim` pays the
/// difference between that total and what the account has already been paid.
///
/// Leaves follow OpenZeppelin's StandardMerkleTree: keccak256(bytes.concat(keccak256(abi.encode(account,
/// cumulative)))), with sorted pair hashing. The tree and its data file are published at `uri` so anyone
/// can recompute them.
///
/// Safety: a root can never allocate more than this contract has paid out plus what it holds, and
/// claims in total can never exceed the allocation the current root declares. There is no owner and no
/// way to take holders' tokens out other than `claim`, which always pays the account in the leaf,
/// whoever calls it. Not independently audited.
contract AixDistributor {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    /// The only address that can post roots: the payout wallet.
    address public immutable poster;

    bytes32 public root;
    /// Total the current root allocates across every account, cumulative since the first root.
    uint256 public totalAllocated;
    /// Total paid out by `claim` since deployment.
    uint256 public claimedTotal;
    /// Where the current root's data file is published.
    string public uri;
    /// Number of roots posted so far.
    uint256 public epoch;

    /// Cumulative amount paid to each account.
    mapping(address => uint256) public claimed;

    event RootPosted(uint256 indexed epoch, bytes32 indexed root, uint256 totalAllocated, string uri);
    event Claimed(address indexed account, address indexed caller, uint256 amount, uint256 cumulative);

    error NotPoster();
    error OverAllocated(uint256 totalAllocated, uint256 available);
    error BelowClaimed(uint256 totalAllocated, uint256 claimedTotal);
    error InvalidProof();
    error NothingToClaim();
    error ExceedsAllocation();
    error ZeroAddress();

    constructor(IERC20 token_, address poster_) {
        if (address(token_) == address(0) || poster_ == address(0)) revert ZeroAddress();
        token = token_;
        poster = poster_;
    }

    /// @notice Replace the root. Called once a day after the day's shares arrive.
    /// @param totalAllocated_ the sum of every leaf's cumulative amount in the new tree.
    function setRoot(bytes32 root_, uint256 totalAllocated_, string calldata uri_) external {
        if (msg.sender != poster) revert NotPoster();
        uint256 available = claimedTotal + token.balanceOf(address(this));
        if (totalAllocated_ > available) revert OverAllocated(totalAllocated_, available);
        if (totalAllocated_ < claimedTotal) revert BelowClaimed(totalAllocated_, claimedTotal);
        root = root_;
        totalAllocated = totalAllocated_;
        uri = uri_;
        unchecked {
            epoch++;
        }
        emit RootPosted(epoch, root_, totalAllocated_, uri_);
    }

    /// @notice Pay `account` what it is owed under the current root. Anyone may call; `account` is paid.
    /// @param cumulative the account's total in the current tree, since the first day.
    /// @return amount what was paid now.
    function claim(address account, uint256 cumulative, bytes32[] calldata proof) external returns (uint256 amount) {
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(account, cumulative))));
        if (!MerkleProof.verifyCalldata(proof, root, leaf)) revert InvalidProof();
        uint256 already = claimed[account];
        if (cumulative <= already) revert NothingToClaim();
        amount = cumulative - already;
        if (claimedTotal + amount > totalAllocated) revert ExceedsAllocation();
        claimed[account] = cumulative;
        claimedTotal += amount;
        token.safeTransfer(account, amount);
        emit Claimed(account, msg.sender, amount, cumulative);
    }

    /// @notice What `account` could claim now, given its leaf. Does not check the proof.
    function claimable(address account, uint256 cumulative) external view returns (uint256) {
        uint256 already = claimed[account];
        return cumulative > already ? cumulative - already : 0;
    }
}
