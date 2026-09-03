// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MetricReentrancyGuardTransient} from "@metric-core/utils/MetricReentrancyGuardTransient.sol";
import {IMetricOmmSimpleRouter} from "../contracts/interfaces/IMetricOmmSimpleRouter.sol";
import {IMetricOmmSwapQuoter} from "../contracts/interfaces/IMetricOmmSwapQuoter.sol";
import {SimpleRouterTestBase} from "./helpers/SimpleRouterTestBase.sol";

/// @notice Audit regression checks for connected paths that reuse one pool in opposite directions.
contract MetricOmmRouterRepeatedPoolAuditTest is SimpleRouterTestBase {
  function test_exactInputRepeatedPoolExecutesButLiveQuoteUsesRolledBackState() public {
    uint128 amountIn = 1_000;
    address[] memory pools = _repeatedPools();
    bytes[] memory extensionDatas = new bytes[](2);

    (, uint256 quotedOut) = quoter.quoteLiveExactIn(
      IMetricOmmSwapQuoter.QuoteExactInputParams({
        pools: pools,
        extensionDatas: extensionDatas,
        zeroForOneBitMap: 1, // WETH -> token1, then token1 -> WETH.
        amountIn: amountIn
      })
    );

    address[] memory tokens = _cyclicTokens();
    vm.prank(swapper);
    uint256 actualOut = router.exactInput(
      IMetricOmmSimpleRouter.ExactInputParams({
        tokens: tokens,
        pools: pools,
        extensionDatas: extensionDatas,
        zeroForOneBitMap: 1,
        amountIn: amountIn,
        amountOutMinimum: 0,
        recipient: recipient,
        deadline: _deadline()
      })
    );

    // Execution's second hop sees state changed by hop one. The quoter's callback revert rolls hop
    // one back before quoting hop two, so it evaluates both legs against the initial pool state.
    assertNotEq(quotedOut, actualOut, "repeated-pool quote unexpectedly matched sequential execution");
  }

  function test_exactOutputRepeatedPoolIsQuotedButCannotExecute() public {
    uint128 amountOut = 1_000;
    address[] memory pools = _repeatedPools();
    bytes[] memory extensionDatas = new bytes[](2);

    (uint256 quotedIn, uint256 quotedOut) = quoter.quoteLiveExactOut(
      IMetricOmmSwapQuoter.QuoteExactOutputParams({
        pools: pools, extensionDatas: extensionDatas, zeroForOneBitMap: 1, amountOut: amountOut
      })
    );
    assertGt(quotedIn, 0, "quoter should return an apparently executable input");
    assertEq(quotedOut, amountOut);

    // Exact output executes recursively from the last hop. Its callback enters the same pool for
    // the first hop while the last-hop swap is still active, so the pool's transient guard reverts.
    vm.prank(swapper);
    vm.expectRevert(MetricReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
    router.exactOutput(
      IMetricOmmSimpleRouter.ExactOutputParams({
        tokens: _cyclicTokens(),
        pools: pools,
        extensionDatas: extensionDatas,
        zeroForOneBitMap: 1,
        amountOut: amountOut,
        amountInMaximum: type(uint128).max,
        recipient: recipient,
        deadline: _deadline()
      })
    );
  }

  function _repeatedPools() internal view returns (address[] memory pools) {
    pools = new address[](2);
    pools[0] = address(pool);
    pools[1] = address(pool);
  }

  function _cyclicTokens() internal view returns (address[] memory tokens) {
    tokens = new address[](3);
    tokens[0] = address(weth);
    tokens[1] = address(token1);
    tokens[2] = address(weth);
  }
}
