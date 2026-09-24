// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IZapFolio {
    function toAssets(uint256 shares, Math.Rounding rounding) external view returns (address[] memory, uint256[] memory);
    function mint(uint256 shares, address receiver, uint256 minSharesOut) external returns (address[] memory, uint256[] memory);
    function redeem(uint256 shares, address receiver, address[] calldata assets, uint256[] calldata minAmountsOut)
        external
        returns (uint256[] memory);
}

interface IZapFactory {
    function isIndex(address index) external view returns (bool);
}

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @notice Buys an index at its backing, or sells it at its backing, in one transaction.
/// @dev A buy pays ETH or an ERC20 into Uniswap's Universal Router, which buys the basket into this
/// contract; the index mints shares for it straight to the buyer. A sell redeems the shares straight
/// into the router, which sells the basket; the proceeds go to the seller. The router calldata is
/// planned off chain and is only ever run as this contract, against this contract's own balances,
/// so the caller can at worst waste their own payment, and `minSharesOut` / `minOut` bound that.
/// Holds nothing between transactions: every balance it touched is returned to the caller before
/// the call ends. Only indexes the AINDEX factory created are accepted. Not independently audited.
contract IndexZap is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable router;
    IZapFactory public immutable factory;
    /// Currencies the router may leave behind in a plan, returned to the caller with the rest.
    address public immutable weth;
    address public immutable usdg;

    event Bought(address indexed index, address indexed buyer, address payToken, uint256 paid, uint256 shares);
    event Sold(address indexed index, address indexed seller, address outToken, uint256 shares, uint256 received);

    error NotAnIndex();
    error BadPayment();
    error TooLittle(uint256 received, uint256 minimum);

    constructor(address router_, address factory_, address weth_, address usdg_) {
        router = router_;
        factory = IZapFactory(factory_);
        weth = weth_;
        usdg = usdg_;
    }

    /// @notice Buy `shares` of `index` (before its mint fee) with `payAmount` of `payToken`.
    /// @param payToken address(0) for ETH, sent as the call's value; otherwise an ERC20 approved to this contract.
    /// @param minSharesOut The least the buyer accepts after the mint fee.
    /// @param commands Universal Router calldata that buys at least `toAssets(shares, Ceil)` of each basket
    ///        token for this contract, paying from the router's own balance.
    function buy(
        address index,
        uint256 shares,
        uint256 minSharesOut,
        address payToken,
        uint256 payAmount,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external payable nonReentrant returns (uint256 sharesOut) {
        if (!factory.isIndex(index)) revert NotAnIndex();
        if (payToken == address(0)) {
            if (msg.value != payAmount) revert BadPayment();
        } else {
            if (msg.value != 0) revert BadPayment();
            IERC20(payToken).safeTransferFrom(msg.sender, router, payAmount);
        }
        IUniversalRouter(router).execute{value: msg.value}(commands, inputs, deadline);

        (address[] memory assets, uint256[] memory amounts) = IZapFolio(index).toAssets(shares, Math.Rounding.Ceil);
        for (uint256 i; i < assets.length; i++) IERC20(assets[i]).forceApprove(index, amounts[i]);
        uint256 before = IERC20(index).balanceOf(msg.sender);
        IZapFolio(index).mint(shares, msg.sender, minSharesOut);
        sharesOut = IERC20(index).balanceOf(msg.sender) - before;
        for (uint256 i; i < assets.length; i++) {
            IERC20(assets[i]).forceApprove(index, 0);
            _returnAll(assets[i]);
        }
        _returnLeftovers(payToken);
        emit Bought(index, msg.sender, payToken, payAmount, sharesOut);
    }

    /// @notice Sell `shares` of `index` for at least `minOut` of `outToken` (address(0) for ETH).
    /// @param commands Universal Router calldata that sells the router's whole balance of each basket token
    ///        and sends `outToken` to this contract.
    function sell(
        address index,
        uint256 shares,
        address outToken,
        uint256 minOut,
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external nonReentrant returns (uint256 received) {
        if (!factory.isIndex(index)) revert NotAnIndex();
        IERC20(index).safeTransferFrom(msg.sender, address(this), shares);
        (address[] memory assets, uint256[] memory amounts) = IZapFolio(index).toAssets(shares, Math.Rounding.Floor);
        // Straight into the router: redeeming is free and needs no approval, and the router sells from its balance.
        IZapFolio(index).redeem(shares, router, assets, amounts);
        IUniversalRouter(router).execute(commands, inputs, deadline);

        received = outToken == address(0) ? address(this).balance : IERC20(outToken).balanceOf(address(this));
        if (received < minOut) revert TooLittle(received, minOut);
        _returnLeftovers(outToken);
        for (uint256 i; i < assets.length; i++) _returnAll(assets[i]);
        emit Sold(index, msg.sender, outToken, shares, received);
    }

    function _returnLeftovers(address token) private {
        if (token != address(0)) _returnAll(token);
        _returnAll(weth);
        _returnAll(usdg);
        uint256 eth = address(this).balance;
        if (eth > 0) {
            (bool ok,) = msg.sender.call{value: eth}("");
            require(ok, "ETH refund failed");
        }
    }

    function _returnAll(address token) private {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) IERC20(token).safeTransfer(msg.sender, bal);
    }

    /// The router returns unspent ETH here, and a sell can pay out in ETH.
    receive() external payable {}
}
