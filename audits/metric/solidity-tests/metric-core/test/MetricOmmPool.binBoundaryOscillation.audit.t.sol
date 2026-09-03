// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MetricOmmPoolBaseTest} from "./MetricOmmPool.base.t.sol";
import {MetricOmmPool} from "../contracts/MetricOmmPool.sol";
import {BinState} from "../contracts/types/PoolStorage.sol";
import {PoolStateTestLib} from "./PoolStateTestLib.sol";

contract MetricOmmPoolBinBoundaryOscillationAuditTest is MetricOmmPoolBaseTest {
  uint256 internal constant SWAPPER = 0;
  uint256 internal constant LP = 1;
  uint256 internal constant Q64_LOCAL = 1 << 64;
  uint104 internal constant SHARES = 1e23;
  uint16 internal constant MAX_ADDITIONAL_FEE_E6 = type(uint16).max;

  function test_boundaryQuoteUsesStoredBinFeeInsteadOfTradableAdjacentBinFee() public {
    BinState[] memory nonNegative = new BinState[](1);
    BinState[] memory negative = new BinState[](1);

    // The cursor starts at bin 0, position 0. A token0 -> token1 swap cannot
    // trade there and must first step down to bin -1.
    nonNegative[0] =
      BinState({token0BalanceScaled: 0, token1BalanceScaled: 0, lengthE6: 100, addFeeBuyE6: 0, addFeeSellE6: 0});
    negative[0] = BinState({
      token0BalanceScaled: 0, token1BalanceScaled: 0, lengthE6: 100, addFeeBuyE6: 0, addFeeSellE6: MAX_ADDITIONAL_FEE_E6
    });

    pool = _deployPoolAndRegister(
      PoolDeployParams({
        priceProvider: address(oracle),
        extensions: _emptyExtensions(),
        extensionOrders: _emptyExtensionOrders(),
        immutablePriceProvider: true,
        protocolSpreadFeeE6: 0,
        adminSpreadFeeE6: 0,
        curBinDistFromProvidedPriceE6: 0,
        nonNegativeBinStates: nonNegative,
        negativeBinStates: negative,
        protocolNotionalFeeE8: 0,
        adminNotionalFeeE8: 0,
        immutablePriceProviderForRegistry: address(oracle),
        lowestBin: -1,
        highestBin: 0
      })
    );
    _approveUsersForPool(address(pool));
    _addLiquidity(LP, -1, 0, SHARES, 0);

    (uint128 quotedSellX64,) = pool.getSellAndBuyPrices();

    (int256 amount0Delta, int256 amount1Delta) = _swap(SWAPPER, address(callers[SWAPPER]), true, int128(1e18), 0);
    uint256 realizedSellX64 = Math.mulDiv(uint256(-amount1Delta), Q64_LOCAL, uint256(amount0Delta));

    assertEq(_getCurBinIdx(), -1, "swap did not step into lower tradable bin");
    assertGt(uint256(quotedSellX64), realizedSellX64, "quote unexpectedly included lower-bin sell fee");
    assertGt(
      Math.mulDiv(uint256(quotedSellX64) - realizedSellX64, 1e6, uint256(quotedSellX64)),
      60_000,
      "boundary quote error was not economically significant"
    );
  }

  function test_boundaryQuoteDoesNotWalkAcrossEmptyBinsToExecutableLiquidity() public {
    BinState[] memory nonNegative = new BinState[](1);
    BinState[] memory negative = new BinState[](15);

    nonNegative[0] =
      BinState({token0BalanceScaled: 0, token1BalanceScaled: 0, lengthE6: 100, addFeeBuyE6: 0, addFeeSellE6: 0});
    for (uint256 i; i < negative.length; ++i) {
      negative[i] =
        BinState({token0BalanceScaled: 0, token1BalanceScaled: 0, lengthE6: 65_000, addFeeBuyE6: 0, addFeeSellE6: 0});
    }

    pool = _deployPoolAndRegister(
      PoolDeployParams({
        priceProvider: address(oracle),
        extensions: _emptyExtensions(),
        extensionOrders: _emptyExtensionOrders(),
        immutablePriceProvider: true,
        protocolSpreadFeeE6: 0,
        adminSpreadFeeE6: 0,
        curBinDistFromProvidedPriceE6: 0,
        nonNegativeBinStates: nonNegative,
        negativeBinStates: negative,
        protocolNotionalFeeE8: 0,
        adminNotionalFeeE8: 0,
        immutablePriceProviderForRegistry: address(oracle),
        lowestBin: -15,
        highestBin: 0
      })
    );
    _approveUsersForPool(address(pool));

    // Only the last negative bin is executable. The fourteen bins between the
    // cursor and that liquidity are valid but empty.
    _addLiquidity(LP, -15, -15, SHARES, 0);

    (uint128 quotedSellX64,) = pool.getSellAndBuyPrices();
    uint256 snap = vm.snapshotState();
    (int256 amount0Delta, int256 amount1Delta) = _swap(SWAPPER, address(callers[SWAPPER]), true, int128(1e18), 0);
    uint256 realizedSellX64 = Math.mulDiv(uint256(-amount1Delta), Q64_LOCAL, uint256(amount0Delta));
    vm.revertToState(snap);

    uint256 errorE6 = Math.mulDiv(uint256(quotedSellX64) - realizedSellX64, 1e6, uint256(quotedSellX64));
    emit log_named_decimal_uint("reported marginal sell price", uint256(quotedSellX64), 18);
    emit log_named_decimal_uint("real executable sell price", realizedSellX64, 18);
    emit log_named_decimal_uint("relative quote error", errorE6, 6);

    assertGt(errorE6, 900_000, "empty-bin traversal did not create a greater-than-90% quote error");
  }

  function test_pessimisticBoundaryQuoteCanCreateSandwichTolerance() public {
    BinState[] memory nonNegative = new BinState[](1);
    BinState[] memory negative = new BinState[](1);

    // The reported current bin charges 2%, but a sell at position zero skips
    // it and executes in the adjacent bin, whose fee is zero.
    nonNegative[0] = BinState({
      token0BalanceScaled: 0, token1BalanceScaled: 0, lengthE6: 65_000, addFeeBuyE6: 0, addFeeSellE6: 20_000
    });
    negative[0] =
      BinState({token0BalanceScaled: 0, token1BalanceScaled: 0, lengthE6: 65_000, addFeeBuyE6: 0, addFeeSellE6: 0});

    pool = _deployPoolAndRegister(
      PoolDeployParams({
        priceProvider: address(oracle),
        extensions: _emptyExtensions(),
        extensionOrders: _emptyExtensionOrders(),
        immutablePriceProvider: true,
        protocolSpreadFeeE6: 0,
        adminSpreadFeeE6: 0,
        curBinDistFromProvidedPriceE6: 0,
        nonNegativeBinStates: nonNegative,
        negativeBinStates: negative,
        protocolNotionalFeeE8: 0,
        adminNotionalFeeE8: 0,
        immutablePriceProviderForRegistry: address(oracle),
        lowestBin: -1,
        highestBin: 0
      })
    );
    _approveUsersForPool(address(pool));
    _addLiquidity(LP, -1, -1, 1e24, 0); // 1,000,000 token1 at the boundary.

    uint256 victimInput = 2_500e18;
    uint256 attackerInput = 100_000e18;
    (uint128 quotedSellX64,) = pool.getSellAndBuyPrices();

    // A victim using the documented marginal price with 0.5% slippage derives
    // this minimum. The wrong 2% fee makes it much looser than intended.
    uint256 minimumFromWrongQuote = Math.mulDiv(victimInput, uint256(quotedSellX64) * 995, Q64_LOCAL * 1000);

    uint256 controlSnap = vm.snapshotState();
    (int256 controlIn, int256 controlOut) = _swap(2, address(callers[2]), true, int128(int256(victimInput)), 0);
    uint256 unsandwichedOutput = uint256(-controlOut);
    uint256 executableMarginalX64 = Math.mulDiv(uint256(-controlOut), Q64_LOCAL, uint256(controlIn));
    vm.revertToState(controlSnap);
    uint256 minimumFromExecutableQuote = Math.mulDiv(victimInput, executableMarginalX64 * 995, Q64_LOCAL * 1000);

    uint256 attackerToken1Before = token1.balanceOf(address(callers[SWAPPER]));
    _swap(SWAPPER, address(callers[SWAPPER]), true, int128(int256(attackerInput)), 0);
    (, int256 victimOutDelta) = _swap(2, address(callers[2]), true, int128(int256(victimInput)), 0);
    uint256 victimOutput = uint256(-victimOutDelta);
    _swap(SWAPPER, address(callers[SWAPPER]), false, -int128(int256(attackerInput)), type(uint128).max);
    uint256 attackerProfit = token1.balanceOf(address(callers[SWAPPER])) - attackerToken1Before;
    uint256 victimLoss = unsandwichedOutput - victimOutput;
    uint256 victimLossE6 = Math.mulDiv(victimLoss, 1e6, unsandwichedOutput);

    emit log_named_decimal_uint("minimum from wrong boundary quote", minimumFromWrongQuote, 18);
    emit log_named_decimal_uint("minimum from executable quote", minimumFromExecutableQuote, 18);
    emit log_named_decimal_uint("victim output without sandwich", unsandwichedOutput, 18);
    emit log_named_decimal_uint("victim output after sandwich", victimOutput, 18);
    emit log_named_decimal_uint("victim loss", victimLoss, 18);
    emit log_named_decimal_uint("victim loss percent", victimLossE6, 4);
    emit log_named_decimal_uint("attacker token1 profit", attackerProfit, 18);

    assertGe(victimOutput, minimumFromWrongQuote, "wrong-quote slippage check would revert");
    assertLt(victimOutput, minimumFromExecutableQuote, "correct executable quote would not protect the victim");
    assertGt(victimLoss, 10e18, "victim loss did not exceed $10 at a $1 token1 value");
    assertGt(victimLossE6, 100, "victim loss did not exceed the 0.01% Medium threshold");
    assertGt(attackerProfit, 10e18, "sandwich did not extract more than $10 at a $1 token1 value");
  }

  function test_repeatedFullBoundaryOscillationDoesNotCreateTraderValue() public {
    (BinState[] memory nonNegative, BinState[] memory negative) = _defaultBinStateArrays();
    pool = _deployPoolAndRegister(
      PoolDeployParams({
        priceProvider: address(oracle),
        extensions: _emptyExtensions(),
        extensionOrders: _emptyExtensionOrders(),
        immutablePriceProvider: true,
        protocolSpreadFeeE6: 0,
        adminSpreadFeeE6: 0,
        curBinDistFromProvidedPriceE6: 0,
        nonNegativeBinStates: nonNegative,
        negativeBinStates: negative,
        protocolNotionalFeeE8: 0,
        adminNotionalFeeE8: 0,
        immutablePriceProviderForRegistry: address(oracle),
        lowestBin: -5,
        highestBin: 4
      })
    );
    _approveUsersForPool(address(pool));
    _addLiquidity(LP, -1, 1, SHARES, 0);

    address trader = address(callers[SWAPPER]);
    uint256 valueBefore = token0.balanceOf(trader) + token1.balanceOf(trader);
    (uint104 lowerToken0Before, uint104 lowerToken1Before,,,) = _getBinState(-1);
    (uint104 upperToken0Before, uint104 upperToken1Before,,,) = _getBinState(1);

    for (uint256 i; i < 8; ++i) {
      (uint104 token0InActiveBin,,,,) = _getBinState(0);
      assertGt(token0InActiveBin, 0, "upward leg has no token0 liquidity");

      _swap(SWAPPER, trader, false, _i128ExactOut(uint128(token0InActiveBin)), type(uint128).max);
      assertEq(_getCurBinIdx(), 1, "upward boundary did not canonicalize to next bin");
      assertEq(_getCurPosInBin(), 0, "upward boundary position is not zero");

      (, uint104 token1InActiveBin,,,) = _getBinState(0);
      assertGt(token1InActiveBin, 0, "downward leg has no token1 liquidity");

      _swap(SWAPPER, trader, true, _i128ExactOut(uint128(token1InActiveBin)), 0);
      assertEq(_getCurBinIdx(), -1, "downward boundary did not canonicalize to previous bin");
      assertEq(_getCurPosInBin(), type(uint104).max, "downward boundary position is not max");
    }

    uint256 valueAfter = token0.balanceOf(trader) + token1.balanceOf(trader);
    assertLe(valueAfter, valueBefore, "boundary oscillation created trader value");

    (uint104 lowerToken0After, uint104 lowerToken1After,,,) = _getBinState(-1);
    (uint104 upperToken0After, uint104 upperToken1After,,,) = _getBinState(1);
    assertEq(lowerToken0After, lowerToken0Before, "lower adjacent bin token0 changed while skipped");
    assertEq(lowerToken1After, lowerToken1Before, "lower adjacent bin token1 changed while skipped");
    assertEq(upperToken0After, upperToken0Before, "upper adjacent bin token0 changed while skipped");
    assertEq(upperToken1After, upperToken1Before, "upper adjacent bin token1 changed while skipped");

    assertEq(PoolStateTestLib.curBinIdx(address(pool)), -1);
    assertEq(PoolStateTestLib.curPosInBin(address(pool)), type(uint104).max);
  }
}
