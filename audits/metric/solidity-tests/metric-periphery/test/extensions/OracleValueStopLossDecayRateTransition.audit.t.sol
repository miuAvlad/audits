// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MetricOmmPoolBaseTest, Q64} from "@metric-core-test/MetricOmmPool.base.t.sol";
import {BinState} from "@metric-core/types/PoolStorage.sol";
import {ExtensionOrders} from "@metric-core/types/PoolExtensionsConfig.sol";
import {ExtensionOrderTestLib} from "@metric-core-test/ExtensionOrderTestLib.sol";
import {OracleValueStopLossExtension} from "../../contracts/extensions/OracleValueStopLossExtension.sol";
import {IOracleValueStopLossExtension} from "../../contracts/interfaces/extensions/IOracleValueStopLossExtension.sol";

/// @notice A newly executed decay rate is applied to all time since a bin's previous touch,
/// including time during which a lower rate applied. This can weaken an otherwise active HWM.
contract OracleValueStopLossDecayRateTransitionAuditTest is MetricOmmPoolBaseTest {
  uint256 private constant E6 = 1e6;
  uint256 private constant E8 = 1e8;
  uint32 private constant DRAWDOWN_E6 = 5_000; // 0.5%
  uint32 private constant OLD_DECAY_E8 = 1; // Approximately 0.0864% per day.
  uint32 private constant NEW_DECAY_E8 = 58; // Approximately 5% per day.
  uint32 private constant CONFIG_TIMELOCK = 1 days;
  uint104 private constant LP_SHARES = 100_000e18;
  uint128 private constant PRIME_TOKEN0_OUT = 1e12;
  uint128 private constant ATTACK_TOKEN0_OUT = 50_000e18;
  uint128 private constant BID_PRICE_X64 = uint128((Q64 * 9_995) / 10_000); // 5 bps below mid.
  uint128 private constant ASK_PRICE_X64 = uint128((Q64 * 10_005) / 10_000); // 5 bps above mid.

  OracleValueStopLossExtension private stopLoss;

  function setUp() public override {
    super.setUp();
    vm.warp(1_000_000);
    oracle.setBidAndAskPrice(BID_PRICE_X64, ASK_PRICE_X64);

    stopLoss = new OracleValueStopLossExtension(address(this));
    _deployPoolWithStopLoss();
    _approveUsersForPool(address(pool));
    stopLoss.initialize(address(pool), abi.encode(DRAWDOWN_E6, OLD_DECAY_E8, CONFIG_TIMELOCK));
    _addLiquidity(0, 0, 0, LP_SHARES, 0);

    // Establish a genuine pre-loss watermark under the original nonzero decay policy.
    _swap(0, users[0], false, _i128ExactOut(PRIME_TOKEN0_OUT), type(uint128).max);
  }

  function test_controlOldRateKeepsEnoughWatermarkToBlockTheLoss() public {
    vm.warp(1_000_000 + 2 days);

    (, uint256 hwmAfterIdlePeriod) = stopLoss.currentHighWatermarks(address(pool), 0);
    emit log_named_uint("HWM after two days at the old nonzero rate", hwmAfterIdlePeriod);
    assertGt(hwmAfterIdlePeriod, 990_000, "the original slow decay retains meaningful protection");

    // With no rate transition, the existing watermark rejects the material value loss.
    vm.expectPartialRevert(IOracleValueStopLossExtension.OracleStopLossTriggered.selector);
    _swap(1, users[1], false, _i128ExactOut(ATTACK_TOKEN0_OUT), type(uint128).max);
  }

  function test_rateIncreaseRetroactivelyWeakensHwmAndAllowsTheSameLoss() public {
    (, uint256 initialHwm) = stopLoss.currentHighWatermarks(address(pool), 0);

    // One ordinary day elapses under the original, nonzero decay policy.
    vm.warp(1_000_000 + 1 days);
    (, uint256 hwmBeforeProposal) = stopLoss.currentHighWatermarks(address(pool), 0);

    stopLoss.proposeOracleStopLossDecay(address(pool), NEW_DECAY_E8);
    vm.warp(1_000_000 + 1 days + CONFIG_TIMELOCK);

    // Execution changes only the global rate. The untouched bin is not checkpointed, so the new rate is incorrectly applied to both elapsed days.
    stopLoss.executeOracleStopLossDecay(address(pool));
    (, uint256 hwmImmediatelyAfterExecution) = stopLoss.currentHighWatermarks(address(pool), 0);

    emit log_named_uint("HWM immediately before the rate proposal", hwmBeforeProposal);
    emit log_named_uint("new decay rate E8", NEW_DECAY_E8);
    emit log_named_uint("HWM immediately after execution", hwmImmediatelyAfterExecution);

    assertGt(hwmBeforeProposal, 995_000, "the original slow rate preserves almost all protection");
    assertLt(hwmImmediatelyAfterExecution, 910_000, "the new rate was retroactively applied to both days");

    (uint104 t0Before, uint104 t1Before,,,) = _getBinState(0);
    uint256 metricBefore = _token1Metric(t0Before, t1Before);

    // This is exactly the swap rejected by the control test. The retroactively weakened HWM
    // allows the same inventory loss and adopts the post-swap metric as the new watermark.
    (int256 amount0Delta, int256 amount1Delta) =
      _swap(1, users[1], false, _i128ExactOut(ATTACK_TOKEN0_OUT), type(uint128).max);

    (uint104 t0After, uint104 t1After,,,) = _getBinState(0);
    uint256 metricAfter = _token1Metric(t0After, t1After);
    uint256 correctlyDecayedHwm = initialHwm - Math.mulDiv(initialHwm, uint256(OLD_DECAY_E8) * 2 days, E8);
    uint256 correctPolicyFloor = Math.mulDiv(correctlyDecayedHwm, E6 - DRAWDOWN_E6, E6);
    uint256 excessLossMetric = correctPolicyFloor - metricAfter;

    uint256 excessLossValueAtMid = Math.mulDiv(excessLossMetric, LP_SHARES, E6);
    uint256 lpValueBeforeAtBid = Math.mulDiv(uint256(t0Before), BID_PRICE_X64, Q64) + uint256(t1Before);
    uint256 lpValueAfterAtBid = Math.mulDiv(uint256(t0After), BID_PRICE_X64, Q64) + uint256(t1After);
    uint256 lpLossAtBid = lpValueBeforeAtBid - lpValueAfterAtBid;
    uint256 outputValueAtExternalBid = Math.mulDiv(uint256(-amount0Delta), BID_PRICE_X64, Q64);
    assertGt(outputValueAtExternalBid, uint256(amount1Delta), "the accepted trade is profitable at the oracle bid");
    uint256 profitAtExternalBid = outputValueAtExternalBid - uint256(amount1Delta);
    (, uint256 adoptedPostLossHwm) = stopLoss.currentHighWatermarks(address(pool), 0);

    emit log_named_uint("metric before the accepted loss", metricBefore);
    emit log_named_uint("correct HWM using the old rate for both historical days", correctlyDecayedHwm);
    emit log_named_uint("correct drawdown-plus-decay floor", correctPolicyFloor);
    emit log_named_uint("metric after the accepted loss", metricAfter);
    emit log_named_uint("loss beyond the correct policy floor", excessLossMetric);
    emit log_named_uint("LP value at authenticated bid before", lpValueBeforeAtBid);
    emit log_named_uint("LP value at authenticated bid after", lpValueAfterAtBid);
    emit log_named_uint("total oracle-mid value lost beyond policy", excessLossValueAtMid);
    emit log_named_uint("LP principal loss at authenticated bid", lpLossAtBid);
    emit log_named_uint("token0 output valued at authenticated bid", outputValueAtExternalBid);
    emit log_named_uint("token1 paid including all configured fees", uint256(amount1Delta));
    emit log_named_uint("attacker profit at the authenticated bid", profitAtExternalBid);
    emit log_named_uint("post-loss metric adopted as the new HWM", adoptedPostLossHwm);

    assertLt(metricAfter, correctPolicyFloor, "accepted loss exceeds the correct drawdown-plus-decay floor");
    assertGt(excessLossMetric, E6 / 100, "loss beyond policy exceeds one percent");
    assertGt(lpLossAtBid, profitAtExternalBid, "LP loss also includes value routed to protocol fees");
    assertGt(profitAtExternalBid, 2_000e18, "attacker profit exceeds two percent of the initial bin value");
    assertApproxEqAbs(adoptedPostLossHwm, metricAfter, 1, "the erased epoch is replaced only after the loss");
    assertGt(excessLossValueAtMid, 1_000e18, "loss beyond policy exceeds one percent of the initial bin value");
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
        protocolSpreadFeeE6: 500, // 5 bps.
        adminSpreadFeeE6: 0,
        curBinDistFromProvidedPriceE6: -50_000, // 5% below the oracle midpoint.
        nonNegativeBinStates: nn,
        negativeBinStates: neg,
        protocolNotionalFeeE8: 50_000, // 5 bps.
        adminNotionalFeeE8: 0,
        immutablePriceProviderForRegistry: address(oracle),
        lowestBin: -1,
        highestBin: 0
      })
    );
  }

  function _token1Metric(uint104 t0, uint104 t1) private pure returns (uint256) {
    uint256 midPriceX64 = (uint256(BID_PRICE_X64) + uint256(ASK_PRICE_X64)) / 2;
    uint256 token0InToken1 = Math.mulDiv(uint256(t0), midPriceX64, Q64);
    return Math.mulDiv(token0InToken1, E6, LP_SHARES) + Math.mulDiv(uint256(t1), E6, LP_SHARES);
  }
}
