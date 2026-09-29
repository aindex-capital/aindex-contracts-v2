// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LiquidityLocker, IMarketsLike} from "../../src/LiquidityLocker.sol";
import {ShareMarketRouter} from "../../src/ShareMarketRouter.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/**
 * The official AR10 position moved into a locker on a fork of mainnet, then recentered at backing.
 *
 *   anvil --fork-url https://rpc.ordofi.network --port 8571
 *   AINDEX_FORK_RPC=http://127.0.0.1:8571 \
 *   AINDEX_AR10_NAV_USD18=$(curl -s https://aindex.capital/v2/indexes/0xf922df1f829dc4144d17d1af152d14ede549bb86 | jq -r .valuation.navPerShareUsd18) \
 *   forge test --match-contract LiquidityLockerForkTest -vv
 *
 * Backing comes from the API, as it will for the script: nothing on chain values a basket in dollars.
 * Depth is what a $100 USDG buy gets, against backing and against the pool's own price.
 */
contract LiquidityLockerForkTest is Test {
    using StateLibrary for IPoolManager;

    IPoolManager private constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    ShareMarketRouter private constant ROUTER = ShareMarketRouter(0xCf09BE3c10e4D8D4853589FC4Bc77F822CAD998a);
    IMarketsLike private constant REGISTRY = IMarketsLike(0x2F8015CA784f7eEEb0AbcF854c92A363D58E9f7e);
    address private constant AR10 = 0xf922dF1f829DC4144D17D1aF152d14EDE549bB86;
    address private constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address private constant OFFICIAL = 0x916817f2c44c44f0255249140300E78AfD6c492C;
    int24 private constant FULL_LOWER = -887220;
    int24 private constant FULL_UPPER = 887220;

    PoolKey private key;
    uint256 private nav;
    LiquidityLocker private locker;

    function setUp() public {
        string memory rpc = vm.envOr("AINDEX_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {vm.skip(true); return;}
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 4663, "Wrong target chain");
        // anvil has no ArbSys; answer arbBlockNumber() with the block number in case a hook asks.
        vm.etch(address(0x64), hex"4360005260206000f3");
        nav = vm.envUint("AINDEX_AR10_NAV_USD18");
        key = REGISTRY.marketFor(AR10);
        assertEq(address(key.hooks), 0x640247c04170a8465eCBF76A17293632Ec6B0044);
        emit log_named_uint("Fork block", block.number);
    }

    function testMoveTheOfficialPositionInAndRecenterAtBacking() public {
        emit log_named_decimal_uint("AR10 backing, $", nav, 18);
        vm.startPrank(OFFICIAL);
        _report("before: official full-range position");

        // 1. Out of the router, as the official wallet.
        uint128 official = ROUTER.positionLiquidity(key, OFFICIAL, FULL_LOWER, FULL_UPPER, bytes32(0));
        assertGt(official, 0, "the official wallet holds the position");
        assertEq(PM.getLiquidity(key.toId()), official, "and it is the pool's only liquidity");
        BalanceDelta out = ROUTER.modifyLiquidity(key,
            ModifyLiquidityParams(FULL_LOWER, FULL_UPPER, -int256(uint256(official)), bytes32(0)), 0, 0, block.timestamp);
        uint256 usdg = uint256(int256(out.amount0()));
        uint256 shares = uint256(int256(out.amount1()));
        emit log_named_decimal_uint("withdrawn USDG", usdg, 6);
        emit log_named_decimal_uint("withdrawn AR10", shares, 18);

        // 2. Into a locker, full range, where the pool already is.
        // Deployed as it will be on mainnet: unlocked (unlockAt = now), so the owner can withdraw at any time.
        locker = new LiquidityLocker(PM, REGISTRY, OFFICIAL, uint64(block.timestamp), 1_500, 300, 4 hours, 50);
        IERC20(USDG).approve(address(locker), usdg);
        IERC20(AR10).approve(address(locker), shares);
        uint128 deposited = locker.deposit(AR10, usdg, shares, FULL_LOWER, FULL_UPPER, 0, official * 999 / 1_000, block.timestamp);
        emit log_named_uint("locker liquidity after deposit", deposited);

        // 3. Recenter at backing, full range.
        uint256 valueBefore = _value();
        uint128 full = locker.recenter(_params(FULL_LOWER, FULL_UPPER, 0, deposited * 95 / 100));
        _report("after: locker, full range at backing");
        assertApproxEqRel(_poolUsd(), nav, 1e14, "pool at backing");
        assertGe(_value() + 3, valueBefore, "no value lost beyond rounding");

        // 4. The same tokens in a band of about 2% either side of backing, alone and with a backstop.
        (int24 lower, int24 upper) = _band(200);
        emit log_named_int("band lower tick", lower);
        emit log_named_int("band upper tick", upper);
        uint256 snap = vm.snapshotState();
        uint128 bandOnly = locker.recenter(_params(lower, upper, 0, full));
        _report("after: locker, +-2% band only");
        assertGt(bandOnly, full * 40);
        vm.revertToState(snap);
        uint128 band = locker.recenter(_params(lower, upper, 1_000, full));
        emit log_named_uint("band liquidity with a 10% backstop", band);
        emit log_named_uint("backstop liquidity", locker.backstopLiquidity(AR10));
        _report("after: locker, +-2% band and a 10% full-range backstop");
        assertApproxEqRel(_poolUsd(), nav, 1e14, "pool at backing");
        assertGe(_value() + 3, valueBefore, "no value lost beyond rounding");

        // 5. Deployed unlocked, so the owner can take all of it back at once.
        uint256 u0 = IERC20(USDG).balanceOf(OFFICIAL);
        uint256 s0 = IERC20(AR10).balanceOf(OFFICIAL);
        locker.withdraw(AR10);
        vm.stopPrank();
        uint256 back = (IERC20(AR10).balanceOf(OFFICIAL) - s0) * nav / 1e30 + IERC20(USDG).balanceOf(OFFICIAL) - u0;
        emit log_named_decimal_uint("withdrawn by the owner, $ at backing", back, 6);
        assertEq(PM.getLiquidity(key.toId()), 0);
    }

    // ------------------------------------------------------------------ helpers

    function _params(int24 lower, int24 upper, uint16 backstopBps, uint128 minLiquidity)
        private view returns (LiquidityLocker.Recenter memory r)
    {
        r.index = AR10;
        r.targetSqrtPriceX96 = _sqrtPriceAt(nav);
        r.tickLower = lower;
        r.tickUpper = upper;
        r.toleranceBps = 10;
        r.maxSwapIn = 1e6; // at most $1 of USDG or 1e-12 AR10: the pool is empty during the swap
        r.minLiquidity = minLiquidity;
        r.backstopBps = backstopBps;
        r.deadline = block.timestamp + 600;
    }

    /// @dev USDG is currency0 (6 decimals) and AR10 currency1 (18), so the price is shares per USDG.
    function _sqrtPriceAt(uint256 usd18) private pure returns (uint160) {
        return uint160(Math.sqrt(Math.mulDiv(uint256(1) << 192, 1e30, usd18)));
    }

    function _poolUsd() private view returns (uint256) {
        (uint160 p,,,) = PM.getSlot0(key.toId());
        return Math.mulDiv(uint256(1) << 192, 1e30, uint256(p) * uint256(p));
    }

    function _band(uint256 bps) private view returns (int24 lower, int24 upper) {
        // A higher dollar price is a lower tick here.
        int24 lo = TickMath.getTickAtSqrtPrice(_sqrtPriceAt(nav * (10_000 + bps) / 10_000));
        int24 hi = TickMath.getTickAtSqrtPrice(_sqrtPriceAt(nav * (10_000 - bps) / 10_000));
        lower = lo / 60 * 60;
        upper = (hi / 60 + 1) * 60;
    }

    function _value() private view returns (uint256) {
        (uint256 u, uint256 s) = locker.holdings(AR10);
        return s * nav / 1e30 + u;
    }

    /// @dev Pool price, and what a $20 and a $50 buy pay against backing and where they leave the price.
    function _report(string memory label) private {
        emit log(label);
        uint256 spot = _poolUsd();
        emit log_named_decimal_uint("  pool price, $", spot, 18);
        emit log_named_int("  pool vs backing, bps", (int256(spot) - int256(nav)) * 10_000 / int256(nav));
        emit log_named_uint("  pool liquidity", PM.getLiquidity(key.toId()));
        _buy(20e6);
        _buy(50e6);
    }

    /// @dev A real buy from a fresh wallet, rolled back afterwards.
    function _buy(uint256 usdgIn) private {
        uint256 snap = vm.snapshotState();
        address buyer = address(0xB0B);
        vm.stopPrank();
        vm.prank(address(PM)); // the PoolManager holds USDG; any funded wallet would do
        IERC20(USDG).transfer(buyer, usdgIn);
        vm.startPrank(buyer);
        IERC20(USDG).approve(address(ROUTER), usdgIn);
        BalanceDelta d = ROUTER.swapExactInput(key, true, usdgIn, 1, TickMath.MIN_SQRT_PRICE + 1, block.timestamp);
        vm.stopPrank();
        uint256 paid = uint256(-int256(d.amount0()));
        uint256 got = uint256(int256(d.amount1()));
        uint256 average = paid * 1e30 / got;
        emit log_named_decimal_uint(string.concat("  $", vm.toString(usdgIn / 1e6), " buy: AR10 received"), got, 18);
        emit log_named_int("    average paid over backing, bps", (int256(average) - int256(nav)) * 10_000 / int256(nav));
        emit log_named_decimal_uint("    pool price after, $", _poolUsd(), 18);
        vm.revertToState(snap);
        vm.startPrank(OFFICIAL);
    }
}
