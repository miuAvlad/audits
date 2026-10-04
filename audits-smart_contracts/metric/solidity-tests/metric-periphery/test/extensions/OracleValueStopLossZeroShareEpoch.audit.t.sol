// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MetricOmmPoolBaseTest, Q64} from "@metric-core-test/MetricOmmPool.base.t.sol";
import {ExtensionOrderTestLib} from "@metric-core-test/ExtensionOrderTestLib.sol";
import {IOracleValueStopLossExtension} from "../../contracts/interfaces/extensions/IOracleValueStopLossExtension.sol";
import {OracleValueStopLossExtension} from "../../contracts/extensions/OracleValueStopLossExtension.sol";
import {ExtensionOrders} from "@metric-core/types/PoolExtensionsConfig.sol";
import {BinState} from "@metric-core/types/PoolStorage.sol";

/// @notice A bin's high watermark is not tied to its liquidity epoch. After totalShares reaches
/// zero, unrelated liquidity can be deposited later and is compared against the former LPs' HWM.
contract OracleValueStopLossZeroShareEpochAuditTest is MetricOmmPoolBaseTest {
  uint32 private constant DRAWDOWN_E6 = 50_000; // 5%
  uint32 private constant DECAY_E8 = 58; // documented approximately 5% per day
  uint32 private constant CONFIG_TIMELOCK = 3 days; // first-party representative configuration
  uint104 private constant HONEST_SHARES = 1e23; // 100,000 tokens with the base-test density
  uint104 private constant PRIME_SHARES = 1e18; // one token, recovered before the attack
  uint104 private constant BARRIER_SHARES = 1_000; // minimalMintableLiquidity

  OracleValueStopLossExtension private stopLoss;

  function setUp() public override {
    super.setUp();
    vm.warp(1_000_000);

    stopLoss = new OracleValueStopLossExtension(address(this));
    _deployPoolWithStopLoss();
    _approveUsersForPool(address(pool));
    stopLoss.initialize(address(pool), abi.encode(DRAWDOWN_E6, DECAY_E8, CONFIG_TIMELOCK));
  }

  function test_staleWatermarkBlocksACompletelyNewLiquidityEpoch() public {
    uint256 barrierCost = _prepareStaleEpochBarrier();

    (uint104 downstreamToken0, uint104 downstreamToken1,,,) = _getBinState(-1);
    (uint256 staleHwm0,) = stopLoss.currentHighWatermarks(address(pool), 1);

    emit log_named_uint("stale token0 HWM inherited by new bin epoch", staleHwm0);
    emit log_named_uint("attacker barrier cost in raw token1 units", barrierCost);
    emit log_named_uint("honest downstream token1 blocked in raw units", downstreamToken1);

    assertEq(downstreamToken0, 0, "honest downstream bin contains token1");
    assertGt(downstreamToken1, 99_000e18, "roughly 100,000 honest tokens sit downstream");
    assertEq(barrierCost, BARRIER_SHARES, "barrier costs only minimum-liquidity raw units");
    assertEq(staleHwm0, 1e6, "new LP inherits the former token0-only epoch's HWM");

    // The new bin-1 LP deposited after the 20% oracle move and has suffered no drawdown.
    // Nevertheless, a swap trying to pass its tiny position and reach bin -1 is rejected.
    vm.expectPartialRevert(IOracleValueStopLossExtension.OracleStopLossTriggered.selector);
    _swap(3, users[3], true, _i128ExactIn(1e18), 0);

    // The pool admin has a targeted repair, but the configured timelock prevents an emergency
    // reset. This delay affects recovery only; the permissionless false barrier already exists.
    uint256 resetAt = block.timestamp + CONFIG_TIMELOCK;
    stopLoss.proposeOracleStopLossHighWatermarks(address(pool), 1, 0, 0);
    vm.expectRevert(
      abi.encodeWithSelector(
        IOracleValueStopLossExtension.OracleStopLossTimelockNotElapsed.selector, resetAt, block.timestamp
      )
    );
    stopLoss.executeOracleStopLossHighWatermarks(address(pool));

    vm.warp(resetAt);
    stopLoss.executeOracleStopLossHighWatermarks(address(pool));

    // Once the stale epoch watermark is cleared, the route is executable again.
    (int256 amount0Delta, int256 amount1Delta) = _swap(3, users[3], true, _i128ExactIn(1e18), 0);
    assertGt(amount0Delta, 0);
    assertLt(amount1Delta, 0, "swap reaches token1 liquidity once stale epoch state is removed");
  }

  function test_realisticDecayLeavesTheFalseBarrierForMultipleDays() public {
    _prepareStaleEpochBarrier();

    vm.warp(block.timestamp + 2 days);
    vm.expectPartialRevert(IOracleValueStopLossExtension.OracleStopLossTriggered.selector);
    _swap(3, users[3], true, _i128ExactIn(1e18), 0);

    // At 58 E8 units/second, three uninterrupted days decay the old HWM enough for the
    // 20%-repriced, token1-only epoch. Until then, the new position is a false barrier.
    vm.warp(block.timestamp + 1 days);
    (int256 amount0Delta, int256 amount1Delta) = _swap(3, users[3], true, _i128ExactIn(1e18), 0);
    assertGt(amount0Delta, 0);
    assertLt(amount1Delta, 0);
  }

  function _prepareStaleEpochBarrier() private returns (uint256 barrierToken1Cost) {
    // Temporary bin-0 liquidity is used only to prime bin 1's watermark. It is removed before
    // repricing so it cannot contribute a separate, legitimate stop-loss breach.
    _addLiquidity(0, 0, 0, PRIME_SHARES, 3);

    // The attacker temporarily owns bin 1 while it is above the cursor, so it contains token0.
    _addLiquidity(0, 1, 1, PRIME_SHARES, 0);

    // Consume bin 0 and land at bin 1's lower boundary. Inclusive stop-loss accounting primes
    // bin 1 at metricToken0 = 1e6 even though its liquidity was not consumed.
    (uint104 bin0Token0,,,,) = _getBinState(0);
    _swap(2, users[2], false, _i128ExactOut(bin0Token0), type(uint128).max);
    assertEq(_getCurBinIdx(), 1);
    assertEq(_getCurPosInBin(), 0);

    (uint256 primedHwm0,) = stopLoss.currentHighWatermarks(address(pool), 1);
    assertEq(primedHwm0, 1e6);

    _removeLiquidity(0, 0, 0, PRIME_SHARES, 3);
    assertEq(_getBinTotalShares(0), 0, "temporary priming liquidity is gone");

    // Ending the liquidity epoch does not delete the watermark.
    _removeLiquidity(0, 1, 1, PRIME_SHARES, 0);
    assertEq(_getBinTotalShares(1), 0, "old bin epoch is completely gone");

    // Move the cursor above bin 1 while it is empty. Its old HWM is skipped, not reset.
    _addLiquidity(0, 2, 2, PRIME_SHARES, 1);
    _swap(2, users[2], false, _i128ExactOut(1), type(uint128).max);
    assertEq(_getCurBinIdx(), 2);
    _removeLiquidity(0, 2, 2, PRIME_SHARES, 1);

    // A normal 20% market move occurs. Bin 1 is now below the cursor, so a brand-new minimum
    // position contains token1 and has metricToken0 ~= 1e6 / 1.2 = 833,333.
    uint128 repricedBid = uint128((Q64 * 12) / 10);
    oracle.setBidAndAskPrice(repricedBid, repricedBid + 1);

    // This honest downstream position belongs entirely to the new price epoch. The extension
    // has never observed bin -1, so it has no watermark capable of independently blocking it.
    _addLiquidity(1, -1, -1, HONEST_SHARES, 0);
    (uint256 downstreamHwm0,) = stopLoss.currentHighWatermarks(address(pool), -1);
    assertEq(downstreamHwm0, 0, "downstream bin has no old watermark");

    (, barrierToken1Cost) = _addLiquidity(0, 1, 1, BARRIER_SHARES, 2);
    assertEq(_getBinTotalShares(1), BARRIER_SHARES, "brand-new epoch uses minimum shares");
  }

  function _deployPoolWithStopLoss() private {
    (BinState[] memory nn, BinState[] memory neg) = _defaultBinStateArrays();
    pool = _deployPoolAndRegister(
      PoolDeployParams({
        priceProvider: address(oracle),
        extensions: _singleExtensionPoolExtensions(address(stopLoss)),
        extensionOrders: _afterSwapOrder(),
        immutablePriceProvider: true,
        protocolSpreadFeeE6: 0,
        adminSpreadFeeE6: 0,
        curBinDistFromProvidedPriceE6: 0,
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

  function _afterSwapOrder() private pure returns (ExtensionOrders memory orders) {
    orders.afterSwap = ExtensionOrderTestLib.encodeExtensionOrder(1, 0, 0, 0, 0, 0, 0);
  }
}
