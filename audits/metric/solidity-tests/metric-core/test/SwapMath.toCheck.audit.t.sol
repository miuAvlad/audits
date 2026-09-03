// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test, console2} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SwapMath} from "../contracts/libraries/SwapMath.sol";
import {BinState} from "../contracts/types/PoolStorage.sol";

contract BuyToken1SpecifiedInAuditHarness {
  function swap(
    BinState memory binState,
    uint104 currBinPos,
    uint256 input,
    uint256 feeX64,
    uint128 lowerPriceX64,
    uint128 upperPriceX64,
    uint128 priceLimitX64
  ) external pure returns (uint104 finalBinPos, uint256 output, uint256 consumedInput, BinState memory finalBinState) {
    SwapMath.SwapState memory state = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: input,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    uint256 finalPos;
    (finalPos, output,,,) = SwapMath.buyToken1InBinSpecifiedIn(
      binState, currBinPos, state, feeX64, lowerPriceX64, upperPriceX64, priceLimitX64, 0
    );

    finalBinPos = uint104(finalPos);
    consumedInput = input - state.amountSpecifiedRemainingScaled;
    finalBinState = binState;
  }

  function requiredInputForMovement(
    uint104 token1Balance,
    uint104 currBinPos,
    uint104 finalBinPos,
    uint256 feeX64,
    uint128 lowerPriceX64,
    uint128 upperPriceX64
  ) external pure returns (uint256 output, uint256 grossInput) {
    output = SwapMath.calculateOutputToken1FromBinPosition(token1Balance, currBinPos, finalBinPos);
    uint256 startPrice =
      SwapMath.calculatePriceAtBinPosition(lowerPriceX64, upperPriceX64, currBinPos, Math.Rounding.Floor);
    uint256 finalPrice =
      SwapMath.calculatePriceAtBinPosition(lowerPriceX64, upperPriceX64, finalBinPos, Math.Rounding.Floor);
    uint256 averageInvertedPrice =
      SwapMath.calculateArithmeticMean(SwapMath.invertPriceX64(startPrice), SwapMath.invertPriceX64(finalPrice));
    uint256 netInput = SwapMath.calculateRequiredToken(output, averageInvertedPrice);
    grossInput = SwapMath.grossInputWithBinFeeCeil(netInput, (1 << 64) + feeX64);
  }

  function requiredInputForOutput(
    uint256 output,
    uint104 currBinPos,
    uint104 finalBinPos,
    uint256 feeX64,
    uint128 lowerPriceX64,
    uint128 upperPriceX64
  ) external pure returns (uint256 grossInput) {
    uint256 startPrice = SwapMath.calculatePriceAtBinPosition(
      lowerPriceX64, upperPriceX64, currBinPos, Math.Rounding.Floor
    );
    uint256 finalPrice =
      SwapMath.calculatePriceAtBinPosition(lowerPriceX64, upperPriceX64, finalBinPos, Math.Rounding.Floor);
    uint256 averageInvertedPrice =
      SwapMath.calculateArithmeticMean(SwapMath.invertPriceX64(startPrice), SwapMath.invertPriceX64(finalPrice));
    uint256 netInput = SwapMath.calculateRequiredToken(output, averageInvertedPrice);
    grossInput = SwapMath.grossInputWithBinFeeCeil(netInput, (1 << 64) + feeX64);
  }

  function swapUp(
    BinState memory binState,
    uint104 currBinPos,
    uint256 input,
    uint256 feeX64,
    uint128 lowerPriceX64,
    uint128 upperPriceX64
  ) external pure returns (uint104 finalBinPos, uint256 output, uint256 consumedInput, BinState memory finalBinState) {
    SwapMath.SwapState memory state = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: input,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });
    uint256 finalPos;
    (finalPos, output,,,) = SwapMath.buyToken0InBinSpecifiedIn(
      binState, currBinPos, state, feeX64, lowerPriceX64, upperPriceX64, type(uint128).max, 0
    );
    finalBinPos = uint104(finalPos);
    consumedInput = input - state.amountSpecifiedRemainingScaled;
    finalBinState = binState;
  }

  function swapUpSpecifiedOut(
    BinState memory binState,
    uint104 currBinPos,
    uint256 output,
    uint256 feeX64,
    uint128 lowerPriceX64,
    uint128 upperPriceX64
  ) external pure returns (uint104 finalBinPos, uint256 input, uint256 consumedOutput, BinState memory finalBinState) {
    SwapMath.SwapState memory state = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: output,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });
    uint256 finalPos;
    (finalPos,,,) = SwapMath.buyToken0InBinSpecifiedOut(
      binState, currBinPos, state, feeX64, lowerPriceX64, upperPriceX64, type(uint128).max, 0
    );
    finalBinPos = uint104(finalPos);
    input = state.amountCalculatedScaled;
    consumedOutput = output - state.amountSpecifiedRemainingScaled;
    finalBinState = binState;
  }
}

contract SwapMathToCheckAuditTest is Test {
  uint256 internal constant Q64 = 1 << 64;
  uint104 internal constant MAX_POS = type(uint104).max;

  BuyToken1SpecifiedInAuditHarness internal harness;

  function setUp() public {
    harness = new BuyToken1SpecifiedInAuditHarness();
  }

  function test_fragmentationAdvantage_extremeFactoryValidBin() public view {
    // Factory-valid geometry: distance starts at -999_999 E6 and a uint16-max
    // bin ends at -934_464 E6. Relative to the oracle mid, prices are
    // 0.000001 and 0.065536, respectively.
    uint128 lower = uint128(Q64 / 1_000_000);
    uint128 upper = uint128(Math.mulDiv(Q64, 65_536, 1_000_000));
    uint104 liquidity = 1e18;
    uint104 finalPos = uint104(uint256(MAX_POS) / 2);

    (uint256 oneOutput, uint256 oneInput) =
      harness.requiredInputForMovement(liquidity, MAX_POS, finalPos, 0, lower, upper);

    uint256 splitInput;
    uint256 splitOutput;
    uint104 balance = liquidity;
    uint104 position = MAX_POS;
    uint256 parts = 64;
    for (uint256 i; i < parts; ++i) {
      uint104 nextPosition = uint104(uint256(MAX_POS) - Math.mulDiv(uint256(MAX_POS) - uint256(finalPos), i + 1, parts));
      (uint256 partOutput, uint256 partInput) =
        harness.requiredInputForMovement(balance, position, nextPosition, 0, lower, upper);
      splitOutput += partOutput;
      splitInput += partInput;
      balance -= uint104(partOutput);
      position = nextPosition;
    }

    console2.log("one-shot output", oneOutput);
    console2.log("split output", splitOutput);
    console2.log("one-shot input", oneInput);
    console2.log("split input", splitInput);
    console2.log("input saving bps", Math.mulDiv(oneInput - splitInput, 10_000, oneInput));

    assertApproxEqAbs(splitOutput, oneOutput, parts, "position path should release the same inventory");
    assertLt(splitInput, oneInput, "fragmentation should lower the inverted-price trapezoid cost");
  }

  function test_exactInputFragmentationPersistsWithDocumentedWidthFee_butRoundTripDoesNotProfit() public view {
    uint128 lower = uint128(Q64);
    uint128 upper = uint128(Math.mulDiv(Q64, 1_065_535, 1_000_000));
    uint104 liquidity = 1e24;
    uint104 halfway = uint104(uint256(MAX_POS) / 2);
    // The analysis document recommends roughly 25% of bin width for narrow
    // bins. Use 1.64% for this maximum-width uint16 bin.
    uint256 feeX64 = Math.mulDiv(16_400, Q64, 1_000_000);
    (, uint256 totalInput) = harness.requiredInputForMovement(liquidity, MAX_POS, halfway, feeX64, lower, upper);

    BinState memory initialBin = BinState({
      token0BalanceScaled: 0,
      token1BalanceScaled: liquidity,
      lengthE6: 65_535,
      addFeeBuyE6: 16_400,
      addFeeSellE6: 16_400
    });
    (, uint256 oneShotOutput,,) = harness.swap(initialBin, MAX_POS, totalInput, feeX64, lower, upper, 0);

    BinState memory splitBin = initialBin;
    uint104 splitPosition = MAX_POS;
    uint256 splitOutput;
    uint256 remainingInput = totalInput;
    uint256 parts = 64;
    for (uint256 i; i < parts; ++i) {
      uint256 partInput = i + 1 == parts ? remainingInput : totalInput / parts;
      remainingInput -= partInput;
      uint256 partOutput;
      (splitPosition, partOutput,, splitBin) = harness.swap(splitBin, splitPosition, partInput, feeX64, lower, upper, 0);
      splitOutput += partOutput;
    }

    console2.log("one-shot exact-input output", oneShotOutput);
    console2.log("split exact-input output", splitOutput);
    console2.log("split output gain bps", Math.mulDiv(splitOutput - oneShotOutput, 10_000, oneShotOutput));

    assertGt(splitOutput, oneShotOutput, "fragmenting exact input should improve execution");

    // Send all token1 obtained by the fragmented leg back through the opposite
    // exact-input path. The configured fee makes the round trip loss-making,
    // so quote path-dependence alone is not an LP drain.
    (, uint256 token0Returned,,) = harness.swapUp(splitBin, splitPosition, splitOutput, feeX64, lower, upper);
    console2.log("token0 initially spent", totalInput);
    console2.log("token0 returned after round trip", token0Returned);
    console2.log("round-trip loss bps", Math.mulDiv(totalInput - token0Returned, 10_000, totalInput));
    assertLt(token0Returned, totalInput, "fragmented round trip unexpectedly profited");
  }

  function test_zeroAdditionalFee_fragmentationStillDoesNotCreateRoundTripProfit() public view {
    uint128 lower = uint128(Q64);
    uint128 upper = uint128(Math.mulDiv(Q64, 1_065_535, 1_000_000));
    uint104 liquidity = 1e24;
    uint104 halfway = uint104(uint256(MAX_POS) / 2);
    (, uint256 totalInput) = harness.requiredInputForMovement(liquidity, MAX_POS, halfway, 0, lower, upper);

    BinState memory bin = BinState({
      token0BalanceScaled: 0, token1BalanceScaled: liquidity, lengthE6: 65_535, addFeeBuyE6: 0, addFeeSellE6: 0
    });
    uint104 position = MAX_POS;
    uint256 token1Received;
    uint256 remainingInput = totalInput;
    uint256 parts = 64;
    for (uint256 i; i < parts; ++i) {
      uint256 partInput = i + 1 == parts ? remainingInput : totalInput / parts;
      remainingInput -= partInput;
      uint256 partOutput;
      (position, partOutput,, bin) = harness.swap(bin, position, partInput, 0, lower, upper, 0);
      token1Received += partOutput;
    }

    uint256 token1Consumed;
    uint256 token0Returned;
    (, token0Returned, token1Consumed,) = harness.swapUp(bin, position, token1Received, 0, lower, upper);
    uint256 token1Remainder = token1Received - token1Consumed;

    console2.log("zero-fee token0 initially spent", totalInput);
    console2.log("zero-fee token0 returned", token0Returned);
    console2.log("zero-fee unspent token1", token1Remainder);
    console2.log("zero-fee round-trip loss", totalInput - token0Returned);

    assertEq(token1Remainder, 0, "reverse leg did not consume the available output");
    assertLt(token0Returned, totalInput, "fragmentation unexpectedly created round-trip profit");
  }

  function test_zeroFee_fragmentedForwardExactOutputReverseDoesNotRealizeReserveDeficit() public view {
    uint128 lower = uint128(Q64);
    uint128 upper = uint128(Math.mulDiv(Q64, 1_065_535, 1_000_000));
    uint104 liquidity = 1e24;
    uint104 halfway = uint104(uint256(MAX_POS) / 2);
    (, uint256 totalInput) = harness.requiredInputForMovement(liquidity, MAX_POS, halfway, 0, lower, upper);

    BinState memory bin = BinState({
      token0BalanceScaled: 0, token1BalanceScaled: liquidity, lengthE6: 65_535, addFeeBuyE6: 0, addFeeSellE6: 0
    });
    uint104 position = MAX_POS;
    uint256 token1Received;
    uint256 remainingInput = totalInput;
    uint256 parts = 64;
    for (uint256 i; i < parts; ++i) {
      uint256 partInput = i + 1 == parts ? remainingInput : totalInput / parts;
      remainingInput -= partInput;
      uint256 partOutput;
      (position, partOutput,, bin) = harness.swap(bin, position, partInput, 0, lower, upper, 0);
      token1Received += partOutput;
    }

    uint256 token0Inventory = bin.token0BalanceScaled;
    (uint104 finalPosition, uint256 token1Required, uint256 token0Returned, BinState memory finalBin) =
      harness.swapUpSpecifiedOut(bin, position, token0Inventory, 0, lower, upper);

    console2.log("forward token0 spent", totalInput);
    console2.log("forward token1 received", token1Received);
    console2.log("reverse token1 required", token1Required);
    console2.log("reverse token0 returned", token0Returned);
    console2.log("token1 round-trip remainder", token1Received > token1Required ? token1Received - token1Required : 0);
    console2.log("final token0 dust", finalBin.token0BalanceScaled);
    console2.log("final token1 surplus", finalBin.token1BalanceScaled > liquidity ? finalBin.token1BalanceScaled - liquidity : 0);

    assertEq(token0Returned, token0Inventory, "reverse leg did not withdraw the requested token0");
    assertEq(finalPosition, MAX_POS, "reverse leg did not restore the cursor");
    assertEq(finalBin.token0BalanceScaled, 0, "reverse leg left token0 inventory");
    assertGe(token1Required, token1Received, "exact-output reverse made the fragmented cycle profitable");
  }

  function test_cursorCanMoveWithoutOutputOrPayment_atPriceLimit() public view {
    uint128 lower = uint128(Q64);
    uint128 upper = uint128(Q64 + Q64 / 100);
    uint104 position = MAX_POS;
    uint104 finalPosition = MAX_POS - 1;
    uint128 priceLimit = uint128(SwapMath.calculatePriceAtBinPosition(lower, upper, finalPosition, Math.Rounding.Floor));
    BinState memory bin =
      BinState({token0BalanceScaled: 0, token1BalanceScaled: 1, lengthE6: 10_000, addFeeBuyE6: 0, addFeeSellE6: 0});

    (uint104 endPosition, uint256 output, uint256 consumedInput, BinState memory endBin) =
      harness.swap(bin, position, 2, 0, lower, upper, priceLimit);

    console2.log("cursor movement", uint256(position) - uint256(endPosition));
    console2.log("output", output);
    console2.log("consumed input", consumedInput);

    assertLt(endPosition, position, "cursor did not move");
    assertEq(output, 0, "expected output to round down");
    assertEq(consumedInput, 0, "no input should be charged");
    assertEq(endBin.token0BalanceScaled, 0);
    assertEq(endBin.token1BalanceScaled, 1);
  }

  function test_rescaledPositionCanPromiseMoreOutputThanWasTransferred() public view {
    uint128 lower = uint128(Q64);
    uint128 upper = uint128(Q64 + Q64 / 10);
    BinState memory bin = BinState({
      token0BalanceScaled: 1e18, token1BalanceScaled: 1e18, lengthE6: 65_535, addFeeBuyE6: 0, addFeeSellE6: 0
    });

    (uint104 endPosition, uint256 output,,) = harness.swap(bin, MAX_POS, 1e16, 0, lower, upper, 0);
    uint256 outputImpliedByCursor =
      SwapMath.calculateOutputToken1FromBinPosition(bin.token1BalanceScaled, MAX_POS, endPosition);

    console2.log("returned output", output);
    console2.log("output implied by cursor", outputImpliedByCursor);
    console2.log("cursor/output mismatch", outputImpliedByCursor - output);

    assertGe(outputImpliedByCursor, output);
  }

  function testFuzz_solverCursorAndOverchargeAreDustBounded(
    uint104 rawPosition,
    uint104 rawLiquidity,
    uint128 rawInput,
    int24 rawDistance,
    uint16 rawLength,
    uint16 rawFeeE6
  ) public view {
    int256 distance = bound(int256(rawDistance), -999_999, 934_463);
    uint256 maxLength = uint256(999_999 - distance);
    uint256 length = bound(uint256(rawLength), 1, maxLength < 65_535 ? maxLength : 65_535);
    uint128 lower = uint128(Math.mulDiv(Q64, uint256(1_000_000 + distance), 1_000_000));
    uint128 upper = uint128(Math.mulDiv(Q64, uint256(1_000_000 + distance) + length, 1_000_000));
    uint104 position = uint104(bound(uint256(rawPosition), 1, MAX_POS));
    uint104 liquidity = uint104(bound(uint256(rawLiquidity), 1, 1e25));
    uint256 input = bound(uint256(rawInput), 1e12, 1e25);
    uint256 feeX64 = Math.mulDiv(uint256(rawFeeE6), Q64, 1_000_000);
    BinState memory bin = BinState({
      token0BalanceScaled: 0,
      token1BalanceScaled: liquidity,
      lengthE6: uint16(length),
      addFeeBuyE6: 0,
      addFeeSellE6: rawFeeE6
    });

    (uint104 endPosition, uint256 output, uint256 consumedInput,) =
      harness.swap(bin, position, input, feeX64, lower, upper, 0);

    uint256 outputImpliedByCursor = SwapMath.calculateOutputToken1FromBinPosition(liquidity, position, endPosition);
    uint256 cursorMismatch =
      outputImpliedByCursor > output ? outputImpliedByCursor - output : output - outputImpliedByCursor;
    assertLe(
      cursorMismatch,
      Math.ceilDiv(uint256(liquidity), uint256(position)) + 1,
      "cursor/output mismatch exceeded one cursor quantum"
    );

    if (consumedInput > 0) {
      uint256 quotedInput = harness.requiredInputForOutput(output, position, endPosition, feeX64, lower, upper);
      uint256 inputMismatch = consumedInput > quotedInput ? consumedInput - quotedInput : quotedInput - consumedInput;
      uint256 largerInput = consumedInput > quotedInput ? consumedInput : quotedInput;
      assertLe(inputMismatch * 10_000, largerInput, "exact-input charge mismatch exceeded one basis point");
    }
  }

  function test_uint104IncomingCapacityRevertsInsteadOfPartialFill() public {
    uint128 lower = uint128(Q64);
    uint128 upper = uint128(Q64 + Q64 / 100);
    BinState memory bin = BinState({
      token0BalanceScaled: MAX_POS - 10, token1BalanceScaled: 1e18, lengthE6: 10_000, addFeeBuyE6: 0, addFeeSellE6: 0
    });

    vm.expectRevert();
    harness.swap(bin, MAX_POS, 11, 0, lower, upper, 0);

    // The immediately smaller trade remains executable, proving the failure is
    // caused by per-bin storage capacity rather than absent outgoing liquidity.
    (, uint256 output, uint256 consumedInput, BinState memory endBin) =
      harness.swap(bin, MAX_POS, 10, 0, lower, upper, 0);
    assertGt(output, 0);
    assertEq(consumedInput, 10);
    assertEq(endBin.token0BalanceScaled, MAX_POS);
  }
}
