// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IMetricOmmSimpleRouter} from "../contracts/interfaces/IMetricOmmSimpleRouter.sol";
import {SimpleRouterTestBase} from "./helpers/SimpleRouterTestBase.sol";

contract PeripheryPaymentsSweepAuditTest is SimpleRouterTestBase {
  address internal attacker;

  function setUp() public override {
    super.setUp();
    attacker = makeAddr("sweep attacker");
  }

  function test_normalUserCanTakeExcessEthLeftAfterDirectSwap() public {
    uint128 amountIn = 2_500;
    uint256 msgValue = 1 ether;

    vm.prank(swapper);
    router.exactInputSingle{value: msgValue}(
      IMetricOmmSimpleRouter.ExactInputSingleParams({
        pool: address(pool),
        tokenIn: address(weth),
        tokenOut: address(token1),
        zeroForOne: true,
        amountIn: amountIn,
        amountOutMinimum: 0,
        recipient: recipient,
        deadline: _deadline(),
        priceLimitX64: 0,
        extensionData: ""
      })
    );

    uint256 stranded = msgValue - amountIn;
    assertEq(address(router).balance, stranded, "direct swap leaves excess msg.value on router");

    uint256 attackerBefore = attacker.balance;
    vm.prank(attacker);
    router.refundETH();

    assertEq(attacker.balance - attackerBefore, stranded, "unrelated caller receives the victim's excess ETH");
    assertEq(address(router).balance, 0, "router ETH was swept");
  }

  function test_exactOutputMaximumNativeInputLeavesPubliclyClaimableRefund() public {
    uint128 amountOut = 1_500;
    (uint256 quotedIn,) =
      quoter.quoteHypotheticalExactOutputSingle(address(pool), true, amountOut, 0, TEST_BID_X64, TEST_ASK_X64);
    uint128 amountInMaximum = uint128(quotedIn * 2);

    vm.prank(swapper);
    uint256 amountIn = router.exactOutputSingle{value: amountInMaximum}(
      IMetricOmmSimpleRouter.ExactOutputSingleParams({
        pool: address(pool),
        tokenIn: address(weth),
        tokenOut: address(token1),
        zeroForOne: true,
        amountOut: amountOut,
        amountInMaximum: amountInMaximum,
        recipient: recipient,
        deadline: _deadline(),
        priceLimitX64: 0,
        extensionData: ""
      })
    );

    uint256 stranded = uint256(amountInMaximum) - amountIn;
    assertGt(stranded, 0, "exact-output maximum did not leave a refund");
    assertEq(address(router).balance, stranded, "unused native input is retained globally");

    uint256 attackerBefore = attacker.balance;
    vm.prank(attacker);
    router.refundETH();

    assertEq(attacker.balance - attackerBefore, stranded, "unrelated caller captured the exact-output refund");
    assertEq(address(router).balance, 0, "router ETH was swept");
  }
}
