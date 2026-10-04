// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MetricOmmPoolBaseTest} from "./MetricOmmPool.base.t.sol";

contract LiquidityRemoveSandwichAuditTest is MetricOmmPoolBaseTest {
  uint80 internal constant SEED_SALT = 1;
  uint80 internal constant VICTIM_SALT = 2;

  function testFuzz_fullWithdrawalDoesNotSubsidizeRoundTrip(
    bool zeroForOne,
    uint96 rawAttackAmount,
    uint96 rawVictimShares,
    uint32 rawReverseFractionE6
  ) public {
    uint104 seedShares = 1e20;
    uint104 victimShares = uint104(bound(uint256(rawVictimShares), MINIMAL_MINTABLE_LIQUIDITY, 1e22));
    _addLiquidity(2, -5, 4, seedShares, SEED_SALT);
    _addLiquidity(1, -5, 4, victimShares, VICTIM_SALT);

    uint128 attackAmount = uint128(bound(uint256(rawAttackAmount), 1e12, 50e18));
    uint256 attackerValueBefore =
      token0.balanceOf(address(callers[0])) + token1.balanceOf(address(callers[0]));

    (int256 firstDelta0, int256 firstDelta1) =
      _swap(0, address(callers[0]), zeroForOne, _i128ExactIn(attackAmount), zeroForOne ? 0 : type(uint128).max);

    // The burn amount remains valid after a swap, but the victim cannot constrain
    // the token composition returned by this state-sensitive withdrawal.
    _removeLiquidity(1, -5, 4, victimShares, VICTIM_SALT);

    uint128 firstOutput = zeroForOne ? _u128FromNegDelta(firstDelta1) : _u128FromNegDelta(firstDelta0);
    uint256 reverseFractionE6 = bound(uint256(rawReverseFractionE6), 0, 1e6);
    uint128 reverseInput = uint128(uint256(firstOutput) * reverseFractionE6 / 1e6);
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
      emit log_named_uint("reverse input", reverseInput);
      emit log_named_uint("attacker profit at 1:1", attackerValueAfter - attackerValueBefore);
    }

    assertLe(attackerValueAfter, attackerValueBefore, "victim withdrawal subsidized attacker round trip");
  }
}
