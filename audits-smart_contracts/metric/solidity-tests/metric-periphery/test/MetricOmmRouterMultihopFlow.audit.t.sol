// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IMetricOmmSimpleRouter} from "../contracts/interfaces/IMetricOmmSimpleRouter.sol";
import {IMetricOmmSwapQuoter} from "../contracts/interfaces/IMetricOmmSwapQuoter.sol";
import {SimpleRouterTestBase} from "./helpers/SimpleRouterTestBase.sol";

contract MetricOmmRouterMultihopFlowAuditTest is SimpleRouterTestBase {
  function test_repeatedPoolQuoteDriftMagnitude() public {
    lpContract.addLiquidityRange(address(pool), 99, -4, 4, 5e17);

    uint128[8] memory amounts = [
      uint128(1e12),
      uint128(1e14),
      uint128(1e16),
      uint128(5e16),
      uint128(1e17),
      uint128(2e17),
      uint128(5e17),
      uint128(1e18)
    ];

    uint256 maxQuoteAboveExecutionE8;
    uint256 maxExecutionAboveQuoteE8;
    uint256 maxExecutionAboveQuoteAbsolute;
    uint256 maxGapAmountIn;
    uint256 maxGapQuotedOut;
    uint256 maxGapActualOut;
    uint256 successfulCases;

    for (uint256 direction; direction < 2; direction++) {
      uint256 bitmap = direction == 0 ? 1 : 2;
      for (uint256 i; i < amounts.length; i++) {
        uint256 snapshot = vm.snapshotState();
        address[] memory pools = _repeatedPools();
        bytes[] memory extensionDatas = new bytes[](2);

        try quoter.quoteLiveExactIn(
          IMetricOmmSwapQuoter.QuoteExactInputParams({
            pools: pools, extensionDatas: extensionDatas, zeroForOneBitMap: bitmap, amountIn: amounts[i]
          })
        ) returns (
          uint256, uint256 quotedOut
        ) {
          vm.prank(swapper);
          try router.exactInput(
            IMetricOmmSimpleRouter.ExactInputParams({
              tokens: _cyclicTokens(direction == 0),
              pools: pools,
              extensionDatas: extensionDatas,
              zeroForOneBitMap: bitmap,
              amountIn: amounts[i],
              amountOutMinimum: 0,
              recipient: recipient,
              deadline: _deadline()
            })
          ) returns (
            uint256 actualOut
          ) {
            successfulCases++;
            if (quotedOut > actualOut && quotedOut != 0) {
              uint256 driftE8 = (quotedOut - actualOut) * 1e8 / quotedOut;
              maxQuoteAboveExecutionE8 = _max(maxQuoteAboveExecutionE8, driftE8);
            } else if (actualOut > quotedOut && quotedOut != 0) {
              uint256 driftE8 = (actualOut - quotedOut) * 1e8 / quotedOut;
              maxExecutionAboveQuoteE8 = _max(maxExecutionAboveQuoteE8, driftE8);
              uint256 absoluteGap = actualOut - quotedOut;
              if (absoluteGap > maxExecutionAboveQuoteAbsolute) {
                maxExecutionAboveQuoteAbsolute = absoluteGap;
                maxGapAmountIn = amounts[i];
                maxGapQuotedOut = quotedOut;
                maxGapActualOut = actualOut;
              }
            }
          } catch {}
        } catch {}

        vm.revertToState(snapshot);
      }
    }

    emit log_named_uint("successful repeated-pool cases", successfulCases);
    emit log_named_uint("max quote above execution (1e8)", maxQuoteAboveExecutionE8);
    emit log_named_uint("max execution above quote (1e8)", maxExecutionAboveQuoteE8);
    emit log_named_uint("largest absolute underquote", maxExecutionAboveQuoteAbsolute);
    emit log_named_uint("input at largest absolute underquote", maxGapAmountIn);
    emit log_named_uint("quoted output there", maxGapQuotedOut);
    emit log_named_uint("actual output there", maxGapActualOut);
    assertGt(successfulCases, 0);
    assertGt(maxQuoteAboveExecutionE8 + maxExecutionAboveQuoteE8, 0);
  }

  function test_searchRepeatedPoolQuoteSandwich() public {
    lpContract.addLiquidityRange(address(pool), 100, -4, 4, 5e17);

    uint128 victimAmountIn = 1e18;
    address[] memory pools = _repeatedPools();
    bytes[] memory extensionDatas = new bytes[](2);
    (, uint256 quotedOut) = quoter.quoteLiveExactIn(
      IMetricOmmSwapQuoter.QuoteExactInputParams({
        pools: pools, extensionDatas: extensionDatas, zeroForOneBitMap: 1, amountIn: victimAmountIn
      })
    );

    uint256 cleanSnapshot = vm.snapshotState();
    vm.prank(swapper);
    uint256 baselineOut = router.exactInput(_cycleParams(victimAmountIn, 0));
    vm.revertToState(cleanSnapshot);

    address attacker = makeAddr("repeated-pool attacker");
    vm.deal(attacker, 20 ether);
    token1.mint(attacker, 20 ether);
    vm.startPrank(attacker);
    weth.deposit{value: 10 ether}();
    weth.approve(address(router), type(uint256).max);
    token1.approve(address(router), type(uint256).max);
    vm.stopPrank();

    uint128[10] memory attackAmounts = [
      uint128(1e13),
      uint128(1e14),
      uint128(1e15),
      uint128(1e16),
      uint128(5e16),
      uint128(1e17),
      uint128(2e17),
      uint128(5e17),
      uint128(1e18),
      uint128(2e18)
    ];

    uint256 bestProfit;
    uint256 successfulSandwiches;

    for (uint256 direction; direction < 2; direction++) {
      bool frontRunZeroForOne = direction == 0;
      for (uint256 i; i < attackAmounts.length; i++) {
        for (uint256 backRunStep; backRunStep < 3; backRunStep++) {
          uint256 snapshot = vm.snapshotState();
          uint256 attackerValueBefore = weth.balanceOf(attacker) + token1.balanceOf(attacker);

          uint256 intermediateOut = _singleSwap(attacker, frontRunZeroForOne, attackAmounts[i]);

          vm.prank(swapper);
          try router.exactInput(_cycleParams(victimAmountIn, uint128(quotedOut))) returns (uint256) {
            successfulSandwiches++;
            uint256 reverseInput = intermediateOut * backRunStep / 2;
            if (reverseInput != 0) {
              _singleSwap(attacker, !frontRunZeroForOne, uint128(reverseInput));
            }

            uint256 attackerValueAfter = weth.balanceOf(attacker) + token1.balanceOf(attacker);
            if (attackerValueAfter > attackerValueBefore && attackerValueAfter - attackerValueBefore > bestProfit) {
              bestProfit = attackerValueAfter - attackerValueBefore;
            }
          } catch {}

          vm.revertToState(snapshot);
        }
      }
    }

    emit log_named_uint("quote-derived minimum", quotedOut);
    emit log_named_uint("clean execution output", baselineOut);
    emit log_named_uint("successful sandwich sizes", successfulSandwiches);
    emit log_named_uint("best attacker profit at 1:1", bestProfit);
  }

  function _singleSwap(address caller, bool zeroForOne, uint128 amountIn) private returns (uint256 amountOut) {
    vm.prank(caller);
    amountOut = router.exactInputSingle(
      IMetricOmmSimpleRouter.ExactInputSingleParams({
        pool: address(pool),
        tokenIn: zeroForOne ? address(weth) : address(token1),
        tokenOut: zeroForOne ? address(token1) : address(weth),
        zeroForOne: zeroForOne,
        amountIn: amountIn,
        amountOutMinimum: 0,
        recipient: caller,
        deadline: _deadline(),
        priceLimitX64: zeroForOne ? 0 : type(uint128).max,
        extensionData: ""
      })
    );
  }

  function _cycleParams(uint128 amountIn, uint128 amountOutMinimum)
    private
    view
    returns (IMetricOmmSimpleRouter.ExactInputParams memory params)
  {
    params = IMetricOmmSimpleRouter.ExactInputParams({
      tokens: _cyclicTokens(true),
      pools: _repeatedPools(),
      extensionDatas: new bytes[](2),
      zeroForOneBitMap: 1,
      amountIn: amountIn,
      amountOutMinimum: amountOutMinimum,
      recipient: recipient,
      deadline: _deadline()
    });
  }

  function _repeatedPools() private view returns (address[] memory pools) {
    pools = new address[](2);
    pools[0] = address(pool);
    pools[1] = address(pool);
  }

  function _cyclicTokens(bool wethFirst) private view returns (address[] memory tokens) {
    tokens = new address[](3);
    tokens[0] = wethFirst ? address(weth) : address(token1);
    tokens[1] = wethFirst ? address(token1) : address(weth);
    tokens[2] = tokens[0];
  }

  function _max(uint256 a, uint256 b) private pure returns (uint256) {
    return a > b ? a : b;
  }
}
