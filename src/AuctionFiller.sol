// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IFillFolio {
    function bid(
        uint256 auctionId,
        IERC20 sellToken,
        IERC20 buyToken,
        uint256 sellAmount,
        uint256 maxBuyAmount,
        bool withCallback,
        bytes calldata data
    ) external returns (uint256 boughtAmt);
}

interface IFillFactory {
    function isIndex(address index) external view returns (bool);
}

interface IFillRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @notice Fills a rebalance auction of an AINDEX index with no inventory, and keeps the margin.
/// @dev A rebalance is one Dutch auction: the index sells what it holds too much of and buys what it
/// holds too little of, at a price that starts favourable to the index and falls. Without a bidder it
/// expires and the rebalance does nothing, so an index run by an agent needs one to exist.
///
/// `fill` bids with a callback. The index pays the sold tokens to this contract first; in the
/// callback the router sells them into USDG and buys exactly what the index is owed, which is paid
/// back before `bid` returns. What is left, in USDG, is the filler's margin and goes to the caller.
/// The call reverts unless that margin is at least `minUsdgOut`, so the caller risks only gas.
///
/// Holds nothing between transactions. Only indexes the AINDEX factory created are accepted, and the
/// callback only answers the index this contract is bidding on at that moment. Router calldata is
/// planned off chain and runs as this contract against this contract's own balances. Not
/// independently audited.
contract AuctionFiller is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable router;
    IFillFactory public immutable factory;
    address public immutable usdg;
    address public immutable weth;

    /// The index being bid on, for the length of one `fill`. Zero otherwise.
    address private active;

    /// Router plans for the two legs. An empty leg is skipped: selling USDG, or buying USDG.
    struct Plan {
        address sellToken;
        bytes sellCommands;
        bytes[] sellInputs;
        /// USDG handed to the router for the buy leg; unspent USDG comes back in the same call.
        uint256 buyPay;
        bytes buyCommands;
        bytes[] buyInputs;
        uint256 deadline;
    }

    event Filled(
        address indexed index,
        uint256 indexed auctionId,
        address indexed keeper,
        address sellToken,
        address buyToken,
        uint256 sold,
        uint256 paid,
        uint256 marginUsdg
    );

    error NotAnIndex();
    error NotActive();
    error TooLittle(uint256 received, uint256 minimum);

    constructor(address router_, address factory_, address usdg_, address weth_) {
        router = router_;
        factory = IFillFactory(factory_);
        usdg = usdg_;
        weth = weth_;
    }

    /// @notice Bid `sellAmount` of `sellToken` against at most `maxBuyAmount` of `buyToken` in `auctionId`.
    /// @param minUsdgOut The least USDG margin the caller accepts; below it the whole fill reverts.
    function fill(
        address index,
        uint256 auctionId,
        address buyToken,
        uint256 sellAmount,
        uint256 maxBuyAmount,
        Plan calldata plan,
        uint256 minUsdgOut
    ) external nonReentrant returns (uint256 margin) {
        if (!factory.isIndex(index)) revert NotAnIndex();
        active = index;
        uint256 paid = IFillFolio(index).bid(
            auctionId, IERC20(plan.sellToken), IERC20(buyToken), sellAmount, maxBuyAmount, true, abi.encode(plan)
        );
        active = address(0);

        margin = IERC20(usdg).balanceOf(address(this));
        if (margin < minUsdgOut) revert TooLittle(margin, minUsdgOut);
        _returnAll(usdg);
        _returnAll(weth);
        _returnAll(plan.sellToken);
        _returnAll(buyToken);
        uint256 eth = address(this).balance;
        if (eth > 0) {
            (bool ok,) = msg.sender.call{value: eth}("");
            require(ok, "ETH refund failed");
        }
        emit Filled(index, auctionId, msg.sender, plan.sellToken, buyToken, sellAmount, paid, margin);
    }

    /// @notice Called by the index inside `bid`, after it has paid the sold tokens here.
    function bidCallback(address buyToken, uint256 buyAmount, bytes calldata data) external {
        if (msg.sender != active || active == address(0)) revert NotActive();
        Plan memory p = abi.decode(data, (Plan));

        // Sell leg: everything the index just paid, into USDG, delivered back here.
        if (p.sellToken != usdg) {
            IERC20(p.sellToken).safeTransfer(router, IERC20(p.sellToken).balanceOf(address(this)));
            IFillRouter(router).execute(p.sellCommands, p.sellInputs, p.deadline);
        }
        // Buy leg: exactly what the index is owed, paid from the USDG the sale produced.
        if (buyToken != usdg) {
            IERC20(usdg).safeTransfer(router, p.buyPay);
            IFillRouter(router).execute(p.buyCommands, p.buyInputs, p.deadline);
        }
        IERC20(buyToken).safeTransfer(msg.sender, buyAmount);
    }

    function _returnAll(address token) private {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) IERC20(token).safeTransfer(msg.sender, bal);
    }

    /// A plan may route through ETH and leave some here; it is returned with the rest.
    receive() external payable {}
}
