// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {console2} from "forge-std/console2.sol";
import {SwapInBinTest, Q64} from "./SwapInBin.t.sol";
import {SwapMath} from "../contracts/libraries/SwapMath.sol";
import {BinState} from "../contracts/types/PoolStorage.sol";

contract SwapMathRoundTripDeficitAuditTest is SwapInBinTest {
  function testFuzz_zeroFeeToken1RoundTripNeverProfits(
    uint104 rawReserve,
    uint104 rawInput,
    uint128 rawLowerPrice,
    uint16 rawWidthE6
  ) public view {
    uint104 reserve = uint104(bound(rawReserve, 1, 1e30));
    uint256 amountIn = bound(rawInput, 1, 1e30);
    uint128 lowerPriceX64 = uint128(bound(rawLowerPrice, 1e12, 1e25));
    uint256 widthE6 = bound(rawWidthE6, 1, 65_535);
    uint128 upperPriceX64 = uint128(uint256(lowerPriceX64) * (1e6 + widthE6) / 1e6);

    BinState memory binState = BinState({
      token0BalanceScaled: 0,
      token1BalanceScaled: reserve,
      lengthE6: uint16(widthE6),
      addFeeBuyE6: 0,
      addFeeSellE6: 0
    });

    SwapMath.SwapState memory forward = _state(amountIn);
    uint128 token1Received;
    uint256 position;
    (position, forward, token1Received, binState) = harness.exposedBuyToken1InBinSpecifiedIn(
      binState, type(uint104).max, forward, 0, lowerPriceX64, upperPriceX64, 0
    );
    vm.assume(token1Received > 0 && binState.token0BalanceScaled > 0);

    SwapMath.SwapState memory reverse = _state(binState.token0BalanceScaled);
    (, reverse, binState) = harness.exposedBuyToken0InBinSpecifiedOut(
      binState, uint104(position), reverse, 0, lowerPriceX64, upperPriceX64, type(uint128).max
    );

    assertGe(reverse.amountCalculatedScaled, token1Received, "profitable token1 round trip");
  }

  function testFuzz_zeroFeeToken0RoundTripNeverProfits(
    uint104 rawReserve,
    uint104 rawInput,
    uint128 rawLowerPrice,
    uint16 rawWidthE6
  ) public view {
    uint104 reserve = uint104(bound(rawReserve, 1, 1e30));
    uint256 amountIn = bound(rawInput, 1, 1e30);
    uint128 lowerPriceX64 = uint128(bound(rawLowerPrice, 1e12, 1e25));
    uint256 widthE6 = bound(rawWidthE6, 1, 65_535);
    uint128 upperPriceX64 = uint128(uint256(lowerPriceX64) * (1e6 + widthE6) / 1e6);

    BinState memory binState = BinState({
      token0BalanceScaled: reserve,
      token1BalanceScaled: 0,
      lengthE6: uint16(widthE6),
      addFeeBuyE6: 0,
      addFeeSellE6: 0
    });

    SwapMath.SwapState memory forward = _state(amountIn);
    uint128 token0Received;
    uint256 position;
    (position, forward, token0Received, binState) = harness.exposedBuyToken0InBinSpecifiedIn(
      binState, 0, forward, 0, lowerPriceX64, upperPriceX64, type(uint128).max
    );
    vm.assume(token0Received > 0 && binState.token1BalanceScaled > 0);

    SwapMath.SwapState memory reverse = _state(binState.token1BalanceScaled);
    (, reverse, binState) =
      harness.exposedBuyToken1InBinSpecifiedOut(binState, uint104(position), reverse, 0, lowerPriceX64, upperPriceX64, 0);

    assertGe(reverse.amountCalculatedScaled, token0Received, "profitable token0 round trip");
  }

  function test_zeroFeeExactInThenExactOutRoundTrip_logsTraderNet() public view {
    uint256 initialToken1 = 1e18;
    BinState memory binState = BinState({
      token0BalanceScaled: 0,
      token1BalanceScaled: uint104(initialToken1),
      lengthE6: 100,
      addFeeBuyE6: 0,
      addFeeSellE6: 0
    });

    uint104 position = type(uint104).max;
    uint128 lowerPriceX64 = uint128(Q64);
    uint128 upperPriceX64 = uint128((Q64 * (1e6 + binState.lengthE6)) / 1e6);

    uint256 traderToken0Spent;
    uint256 traderToken1Received;

    for (uint256 i; i < 2; ++i) {
      SwapMath.SwapState memory forward = _state(4e17);
      uint128 output;
      uint256 nextPosition;
      (nextPosition, forward, output, binState) = harness.exposedBuyToken1InBinSpecifiedIn(
        binState, position, forward, 0, lowerPriceX64, upperPriceX64, 0
      );
      position = uint104(nextPosition);
      traderToken0Spent += 4e17 - forward.amountSpecifiedRemainingScaled;
      traderToken1Received += output;
    }

    uint256 traderToken1Spent;
    for (uint256 i; i < 2; ++i) {
      uint256 token0ToRecover = i == 0 ? uint256(binState.token0BalanceScaled) / 2 : binState.token0BalanceScaled;
      SwapMath.SwapState memory reverse = _state(token0ToRecover);
      uint256 nextPosition;
      (nextPosition, reverse, binState) = harness.exposedBuyToken0InBinSpecifiedOut(
        binState, position, reverse, 0, lowerPriceX64, upperPriceX64, type(uint128).max
      );
      position = uint104(nextPosition);
      traderToken1Spent += reverse.amountCalculatedScaled;
    }

    int256 traderNetToken1 = int256(traderToken1Received) - int256(traderToken1Spent);
    int256 binNetToken1 = int256(uint256(binState.token1BalanceScaled)) - int256(initialToken1);

    console2.log("token0 spent and recovered", traderToken0Spent);
    console2.log("token1 received", traderToken1Received);
    console2.log("token1 paid to reverse", traderToken1Spent);
    console2.log("trader token1 net (negative = loss)");
    console2.logInt(traderNetToken1);
    console2.log("bin token1 net (positive = gain)");
    console2.logInt(binNetToken1);
    console2.log("final position", position);

    assertEq(binState.token0BalanceScaled, 0, "all token0 was recovered");
    assertEq(traderNetToken1 + binNetToken1, 0, "trader/bin conservation mismatch");
  }

  function _state(uint256 amount) private pure returns (SwapMath.SwapState memory) {
    return SwapMath.SwapState({
      amountSpecifiedRemainingScaled: amount,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });
  }
}
