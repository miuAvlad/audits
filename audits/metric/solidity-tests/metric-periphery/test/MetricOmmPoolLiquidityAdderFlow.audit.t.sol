// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {LiquidityDelta} from "@metric-core/types/PoolOperation.sol";
import {IMetricOmmPoolLiquidityAdder} from "../contracts/interfaces/IMetricOmmPoolLiquidityAdder.sol";
import {MetricOmmPoolLiquidityAdderTest} from "./MetricOmmPoolLiquidityAdder.t.sol";

contract MetricOmmPoolLiquidityAdderFlowAuditTest is MetricOmmPoolLiquidityAdderTest {
  function test_weightedAggregateScaleCanMissAFeasibleRoundedVector() public {
    // Put the cursor 90% through bin 0. A 1,000-share seed then owns 101 token0
    // units and 900 token1 units because each pool-side requirement rounds up.
    bytes32 slot = vm.load(address(pool), bytes32(0));
    uint256 raw = uint256(slot);
    uint256 positionMask = uint256(type(uint104).max) << 16;
    uint104 position = uint104(uint256(type(uint104).max) * 9 / 10);
    vm.store(address(pool), bytes32(0), bytes32((raw & ~positionMask) | (uint256(position) << 16)));

    LiquidityDelta memory seed = _deltaAbovePrice(0, 1_000);
    vm.prank(alice);
    helper.addLiquidityExactShares(address(pool), alice, 30, seed, type(uint256).max, type(uint256).max, "");

    // Duplicate rows are valid pool input. The probe for [52, 940] needs
    // 102 token0 units, so max0=2 produces the integer vector [1, 18].
    // Executing [1, 18] needs 3 token0 units due to row-level ceil rounding.
    LiquidityDelta memory weights = _deltaTwoBins(0, 52, 0, 940);
    (int8 minBin, uint104 minPos, int8 maxBin, uint104 maxPos) = _unconstrainedCursorBounds();

    vm.prank(alice);
    vm.expectRevert(abi.encodeWithSelector(IMetricOmmPoolLiquidityAdder.MaxAmountExceeded.selector, 3, 18, 2, 894));
    helper.addLiquidityWeighted(address(pool), alice, 30, weights, 2, 894, minBin, minPos, maxBin, maxPos, "");

    // A smaller common-scale vector remains positive in both rows and fits the
    // exact same caps. The weighted helper simply did not account for rounding.
    LiquidityDelta memory feasible = _deltaTwoBins(0, 1, 0, 9);
    vm.prank(alice);
    (uint256 paid0, uint256 paid1) = helper.addLiquidityExactShares(address(pool), alice, 30, feasible, 2, 894, "");
    assertEq(paid0, 2);
    assertEq(paid1, 10);
  }

  function test_weightedUnlimitedCapCanOverflowScaleCalculation() public {
    LiquidityDelta memory weights = _deltaAbovePrice(4, 100_000);
    (int8 minBin, uint104 minPos, int8 maxBin, uint104 maxPos) = _unconstrainedCursorBounds();

    // Math.mulDiv(maxUint, 1e18, need0) has a quotient larger than uint256
    // whenever 0 < need0 < 1e18, so the conventional unlimited cap reverts.
    vm.prank(alice);
    vm.expectRevert();
    helper.addLiquidityWeighted(
      address(pool), alice, 31, weights, type(uint256).max, type(uint256).max, minBin, minPos, maxBin, maxPos, ""
    );
  }
}
