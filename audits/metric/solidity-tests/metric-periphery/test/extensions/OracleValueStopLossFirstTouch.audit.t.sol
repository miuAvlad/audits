// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MetricOmmPoolBaseTest, Q64} from "@metric-core-test/MetricOmmPool.base.t.sol";
import {BinState} from "@metric-core/types/PoolStorage.sol";
import {ExtensionOrders} from "@metric-core/types/PoolExtensionsConfig.sol";
import {ExtensionOrderTestLib} from "@metric-core-test/ExtensionOrderTestLib.sol";
import {OracleValueStopLossExtension} from "../../contracts/extensions/OracleValueStopLossExtension.sol";

contract OracleValueStopLossFirstTouchAuditTest is MetricOmmPoolBaseTest {
  uint256 private constant E6 = 1e6;
  uint32 private constant DRAWDOWN_E6 = 50_000; // 5%
  uint104 private constant LP_SHARES = 1_000e18; // Default density deposits 1,000 token0.
  uint128 private constant PRIME_TOKEN0_OUT = 1e12;
  uint128 private constant ATTACK_TOKEN0_OUT = 900e18;

  OracleValueStopLossExtension private stopLoss;

  function setUp() public override {
    super.setUp();

    stopLoss = new OracleValueStopLossExtension(address(this));
    _deployPoolWithStopLoss();
    _approveUsersForPool(address(pool));
    stopLoss.initialize(address(pool), abi.encode(DRAWDOWN_E6, uint32(0), uint32(0)));

    // Default share density is 1e18: 1e21 shares deposits 1e21 raw units = 1,000 tokens.
    // The valid -10% cursor distance makes a large token0 purchase lose about 9% at the
    // unchanged 1:1 oracle mark, above the configured 5% stop-loss.
    _addLiquidity(0, 0, 0, LP_SHARES, 0);
  }

  function test_firstSwapCanExceedDrawdownBeforeWatermarkExists() public {
    (, uint256 watermarkBefore) = stopLoss.currentHighWatermarks(address(pool), 0);
    assertEq(watermarkBefore, 0, "newly funded bin has no baseline");

    (uint104 t0Before, uint104 t1Before,,,) = _getBinState(0);
    uint256 metricBefore = _token1Metric(t0Before, t1Before);

    (int256 amount0Delta, int256 amount1Delta) =
      _swap(1, users[1], false, _i128ExactOut(ATTACK_TOKEN0_OUT), type(uint128).max);

    (uint104 t0After, uint104 t1After,,,) = _getBinState(0);
    uint256 metricAfter = _token1Metric(t0After, t1After);
    uint256 stopLossFloor = Math.mulDiv(metricBefore, E6 - DRAWDOWN_E6, E6);
    (, uint256 watermarkAfter) = stopLoss.currentHighWatermarks(address(pool), 0);

    uint256 token0Out = uint256(-amount0Delta);
    uint256 token1In = uint256(amount1Delta);
    uint256 profitAtOracle = token0Out - token1In; // Constant 1:1 oracle.

    emit log_named_uint("pre-swap metric", metricBefore);
    emit log_named_uint("configured 5% floor", stopLossFloor);
    emit log_named_uint("post-swap metric", metricAfter);
    emit log_named_uint("token0 received", token0Out);
    emit log_named_uint("token1 paid", token1In);
    emit log_named_uint("profit at constant oracle", profitAtOracle);
    emit log_named_uint("first watermark recorded after the loss", watermarkAfter);

    assertLt(metricAfter, stopLossFloor, "the first swap loses more than the configured drawdown");
    assertEq(watermarkAfter, metricAfter, "the extension adopts only the already-depleted state");
    assertGt(profitAtOracle, 80e18, "loss is economically material, not rounding dust");
  }

  function test_sameSwapRevertsAfterASeparatePrimingTrade() public {
    // A negligible prior trade is enough to establish the pre-loss value baseline.
    _swap(0, users[0], false, _i128ExactOut(PRIME_TOKEN0_OUT), type(uint128).max);
    (, uint256 initializedWatermark) = stopLoss.currentHighWatermarks(address(pool), 0);
    assertGt(initializedWatermark, 0, "watermark was primed");

    vm.expectRevert();
    _swap(1, users[1], false, _i128ExactOut(ATTACK_TOKEN0_OUT), type(uint128).max);
  }

  function _deployPoolWithStopLoss() private {
    (BinState[] memory nn, BinState[] memory neg) = _defaultBinStateArrays();
    ExtensionOrders memory orders;
    orders.afterSwap = ExtensionOrderTestLib.encodeExtensionOrder(1, 0, 0, 0, 0, 0, 0);

    pool = _deployPoolAndRegister(
      PoolDeployParams({
        priceProvider: address(oracle),
        extensions: _singleExtensionPoolExtensions(address(stopLoss)),
        extensionOrders: orders,
        immutablePriceProvider: true,
        protocolSpreadFeeE6: 0,
        adminSpreadFeeE6: 0,
        curBinDistFromProvidedPriceE6: -100_000,
        nonNegativeBinStates: nn,
        negativeBinStates: neg,
        protocolNotionalFeeE8: 0,
        adminNotionalFeeE8: 0,
        immutablePriceProviderForRegistry: address(oracle),
        lowestBin: -1,
        highestBin: 0
      })
    );
  }

  function _token1Metric(uint104 t0, uint104 t1) private pure returns (uint256) {
    // Oracle is constant at 1:1; this is the extension's unclamped token1 metric.
    return Math.mulDiv(uint256(t0) + uint256(t1), E6, LP_SHARES);
  }
}
