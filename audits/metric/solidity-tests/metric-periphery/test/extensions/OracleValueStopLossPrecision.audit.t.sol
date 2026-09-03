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

contract OracleValueStopLossPrecisionAuditTest is MetricOmmPoolBaseTest {
  uint256 private constant E6 = 1e6;
  uint256 private constant CHECK_PRECISION = 1e18;
  uint256 private constant TOKEN0_DENSITY_E18 = 1e11;
  uint256 private constant TOKEN1_DENSITY_E18 = 1e18;
  uint32 private constant DRAWDOWN_E6 = 50_000; // 5%
  uint104 private constant SHARES = 1e31;
  uint128 private constant PRIME_TOKEN0_OUT = 1e12;
  uint128 private constant BYPASS_TOKEN0_OUT = 9e23;

  OracleValueStopLossExtension internal stopLoss;

  function setUp() public override {
    super.setUp();

    stopLoss = new OracleValueStopLossExtension(address(this));
    _deployHighSharePrecisionPool();
    _approveUsersForPool(address(pool));
    stopLoss.initialize(address(pool), abi.encode(DRAWDOWN_E6, uint32(0), uint32(0)));

    // A valid density of 1e11 and 1e31 shares deposits 1e24 raw units: one million
    // 18-decimal token0. The large share count is bookkeeping, not extra economic value.
    _addLiquidity(0, 0, 0, SHARES, 0);
  }

  function test_fixedMetricScaleRoundsValuableBinToZero() public {
    uint128 highX64 = uint128(Q64);
    oracle.setBidAndAskPrice(highX64, highX64 + 1);

    _swap(0, users[0], false, _i128ExactOut(PRIME_TOKEN0_OUT), type(uint128).max);

    (uint104 t0AtHigh, uint104 t1AtHigh,,,) = _getBinState(0);
    uint256 preciseHighMetric = _token1Metric(t0AtHigh, t1AtHigh, SHARES, highX64, CHECK_PRECISION);
    (, uint256 storedHighMetric) = stopLoss.currentHighWatermarks(address(pool), 0);

    assertGt(preciseHighMetric, 0, "the bin has nonzero value per share at higher precision");
    assertEq(storedHighMetric, 0, "the production 1e6 metric scale rounds the watermark to zero");

    uint128 lowX64 = uint128(Q64 / 10);
    oracle.setBidAndAskPrice(lowX64, lowX64 + 1);

    // A 90% repricing should block this token0-out direction under a 5% stop-loss.
    // It succeeds and removes roughly 90% of a bin containing one million token0.
    _swap(1, users[1], false, _i128ExactOut(BYPASS_TOKEN0_OUT), type(uint128).max);

    (uint104 t0AtLow, uint104 t1AtLow,,,) = _getBinState(0);
    uint256 preciseLowMetric = _token1Metric(t0AtLow, t1AtLow, SHARES, lowX64, CHECK_PRECISION);
    uint256 preciseFivePercentFloor = Math.mulDiv(preciseHighMetric, E6 - DRAWDOWN_E6, E6);
    (, uint256 storedMetricAfterBypass) = stopLoss.currentHighWatermarks(address(pool), 0);

    emit log_named_uint("high metric at 1e18 precision", preciseHighMetric);
    emit log_named_uint("5% floor at 1e18 precision", preciseFivePercentFloor);
    emit log_named_uint("low metric at 1e18 precision", preciseLowMetric);
    emit log_named_uint("production stored watermark", storedMetricAfterBypass);

    assertLt(preciseLowMetric, preciseFivePercentFloor, "the true drawdown greatly exceeds 5%");
    assertEq(storedMetricAfterBypass, 0, "the stop-loss remains completely uninitialized");
    assertLt(t0AtLow, 11e22, "the unblocked swap removes roughly 90% of token0 inventory");
  }

  function _deployHighSharePrecisionPool() private {
    (BinState[] memory nonNegativeBinStates, BinState[] memory negativeBinStates) = _defaultBinStateArrays();
    PoolExtensions memory extensions = _singleExtensionPoolExtensions(address(stopLoss));
    ExtensionOrders memory orders;
    orders.afterSwap = ExtensionOrderTestLib.encodeExtensionOrder(1, 0, 0, 0, 0, 0, 0);

    pool = MetricOmmPool(
      poolDeployer.deploy(
        MetricOmmPoolDeployer.DeployParams({
          salt: keccak256("OracleValueStopLossPrecisionAuditTest"),
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
          minimalMintableLiquidity: 1,
          spreadFeeE6: 0,
          curBinDistFromProvidedPriceE6: 0,
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

  function _token1Metric(uint104 t0, uint104 t1, uint256 shares, uint128 midX64, uint256 precision)
    private
    pure
    returns (uint256)
  {
    uint256 t0InToken1 = Math.mulDiv(uint256(t0), midX64, Q64);
    return Math.mulDiv(t0InToken1, precision, shares) + Math.mulDiv(uint256(t1), precision, shares);
  }
}
