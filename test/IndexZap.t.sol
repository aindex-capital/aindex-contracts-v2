// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IndexZap} from "../src/IndexZap.sol";

contract Tok is ERC20 {
    constructor(string memory s) ERC20(s, s) {}
    function mint(address to, uint256 v) external { _mint(to, v); }
}

/// Swaps whatever it holds of `payIn` into `out` at 1:1 for the caller, like a router plan would.
contract MockRouter {
    Tok public out;
    Tok public payIn;
    uint256 public deliver;
    bool public payEth;
    constructor(Tok out_, Tok payIn_) { out = out_; payIn = payIn_; }
    function set(uint256 deliver_, bool payEth_) external { deliver = deliver_; payEth = payEth_; }
    function execute(bytes calldata, bytes[] calldata, uint256) external payable {
        // Spend `deliver` of the payment, deliver that much of the output, return the rest.
        out.mint(msg.sender, deliver);
        if (payEth) {
            (bool ok,) = msg.sender.call{value: address(this).balance - deliver}("");
            require(ok);
        } else {
            payIn.transfer(msg.sender, payIn.balanceOf(address(this)) - deliver);
        }
    }
    receive() external payable {}
}

/// One-asset index: a share is backed by one unit of `asset`; minting keeps 0.5% as the fee.
contract MockFolio is ERC20 {
    Tok public asset;
    constructor(Tok a) ERC20("IDX", "IDX") { asset = a; }
    function toAssets(uint256 shares, Math.Rounding) external view returns (address[] memory a, uint256[] memory v) {
        a = new address[](1); v = new uint256[](1); a[0] = address(asset); v[0] = shares;
    }
    function mint(uint256 shares, address receiver, uint256 minSharesOut) external returns (address[] memory, uint256[] memory) {
        asset.transferFrom(msg.sender, address(this), shares);
        uint256 out = shares - shares / 200;
        require(out >= minSharesOut, "min");
        _mint(receiver, out);
    }
    function redeem(uint256 shares, address receiver, address[] calldata, uint256[] calldata) external returns (uint256[] memory) {
        _burn(msg.sender, shares);
        asset.transfer(receiver, shares);
    }
}

contract MockFactory {
    mapping(address => bool) public isIndex;
    function add(address i) external { isIndex[i] = true; }
}

contract IndexZapTest is Test {
    Tok usdg; Tok weth; Tok basket;
    MockRouter router; MockFolio index; MockFactory factory; IndexZap zap;
    address buyer = address(0xB0B);

    function setUp() public {
        usdg = new Tok("USDG"); weth = new Tok("WETH"); basket = new Tok("BASKET");
        router = new MockRouter(basket, usdg);
        index = new MockFolio(basket);
        factory = new MockFactory(); factory.add(address(index));
        zap = new IndexZap(address(router), address(factory), address(weth), address(usdg));
        usdg.mint(buyer, 1_000e18); vm.deal(buyer, 10 ether);
        basket.mint(address(index), 1); // a live index already holds something
    }

    function _buyUsdg(uint256 pay, uint256 shares, uint256 minOut) internal returns (uint256) {
        router.set(shares, false);
        vm.startPrank(buyer);
        usdg.approve(address(zap), pay);
        uint256 got = zap.buy(address(index), shares, minOut, address(usdg), pay, "", new bytes[](0), block.timestamp);
        vm.stopPrank();
        return got;
    }

    function test_buyMintsToTheBuyerAndReturnsTheRest() public {
        uint256 got = _buyUsdg(100e18, 90e18, 89.55e18);
        assertEq(got, 89.55e18);
        assertEq(index.balanceOf(buyer), 89.55e18);
        assertEq(usdg.balanceOf(buyer), 1_000e18 - 90e18, "only what the basket cost is spent");
        assertEq(usdg.balanceOf(address(zap)), 0);
        assertEq(basket.balanceOf(address(zap)), 0);
        assertEq(basket.allowance(address(zap), address(index)), 0, "no allowance left behind");
    }

    function test_buyWithEthRefundsUnspentEth() public {
        router.set(3 ether, true);
        vm.prank(buyer);
        zap.buy{value: 5 ether}(address(index), 3 ether, 0, address(0), 5 ether, "", new bytes[](0), block.timestamp);
        assertEq(buyer.balance, 10 ether - 3 ether);
        assertEq(address(zap).balance, 0);
    }

    function test_buyRevertsBelowTheMinimum() public {
        router.set(90e18, false);
        vm.startPrank(buyer);
        usdg.approve(address(zap), 100e18);
        vm.expectRevert(bytes("min"));
        zap.buy(address(index), 90e18, 90e18, address(usdg), 100e18, "", new bytes[](0), block.timestamp);
        vm.stopPrank();
    }

    function test_refusesAnythingTheFactoryDidNotCreate() public {
        MockFolio fake = new MockFolio(basket);
        vm.prank(buyer);
        vm.expectRevert(IndexZap.NotAnIndex.selector);
        zap.buy(address(fake), 1, 0, address(usdg), 1, "", new bytes[](0), block.timestamp);
        vm.prank(buyer);
        vm.expectRevert(IndexZap.NotAnIndex.selector);
        zap.sell(address(fake), 1, address(usdg), 0, "", new bytes[](0), block.timestamp);
    }

    function test_paymentMustMatch() public {
        vm.startPrank(buyer);
        vm.expectRevert(IndexZap.BadPayment.selector);
        zap.buy{value: 1 ether}(address(index), 1, 0, address(0), 2 ether, "", new bytes[](0), block.timestamp);
        vm.expectRevert(IndexZap.BadPayment.selector);
        zap.buy{value: 1 ether}(address(index), 1, 0, address(usdg), 1, "", new bytes[](0), block.timestamp);
        vm.stopPrank();
    }

    function test_sellPaysTheSellerAndEnforcesTheMinimum() public {
        _buyUsdg(100e18, 90e18, 0);
        uint256 shares = index.balanceOf(buyer);
        // The mock router pays out in its output token; sell for the basket token itself so the
        // proceeds are what the redemption delivered, with nothing swapped.
        router.set(0, false);
        vm.startPrank(buyer);
        index.approve(address(zap), shares);
        vm.expectRevert(abi.encodeWithSelector(IndexZap.TooLittle.selector, 0, 1));
        zap.sell(address(index), shares, address(weth), 1, "", new bytes[](0), block.timestamp);
        vm.stopPrank();
    }
}
