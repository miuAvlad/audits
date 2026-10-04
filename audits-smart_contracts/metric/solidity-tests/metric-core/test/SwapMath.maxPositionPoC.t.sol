// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {SwapMath} from "../contracts/libraries/SwapMath.sol";
import {BinState} from "../contracts/types/PoolStorage.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

uint256 constant Q64 = 2 ** 64;

/// @dev Regression for max-bin-position PoC: ETH in / USDC out at uint104.max.
///      Upper price 2001, lower 2000, 10_000 USDC liquidity, 0.3% fee.
contract SwapMathMaxPositionPoCTest is Test {
  uint128 internal lowerPriceX64;
  uint128 internal upperPriceX64;
  uint256 internal feeX64;
  uint104 internal token1Balance;
  uint256 internal currBinPos;

  function setUp() public {
    // forge-lint: disable-next-line(unsafe-typecast) -- `2000 * Q64` fits well within `uint128`.
    lowerPriceX64 = uint128(2000 * Q64);
    // forge-lint: disable-next-line(unsafe-typecast) -- `2001 * Q64` fits well within `uint128`.
    upperPriceX64 = uint128(2001 * Q64);
    feeX64 = Math.mulDiv(3000, Q64, 1e6); // 0.3%
    token1Balance = uint104(10_000 * 1e18);
    currBinPos = type(uint104).max;
  }

  function _swapEthForUsdc(uint256 ethIn) internal view returns (uint256 usdcOut) {
    BinState memory binState = BinState({
      token0BalanceScaled: 0, token1BalanceScaled: token1Balance, lengthE6: 1, addFeeBuyE6: 0, addFeeSellE6: 0
    });

    SwapMath.SwapState memory state = SwapMath.SwapState({
      amountSpecifiedRemainingScaled: ethIn,
      amountCalculatedScaled: 0,
      protocolFeeAmountScaled: 0,
      feeExclusiveInputScaled: 0
    });

    // zeroForOne exact-in uses priceLimit 0 (see MetricOmmPool.swap tests).
    (, usdcOut,,,) =
      SwapMath.buyToken1InBinSpecifiedIn(binState, currBinPos, state, feeX64, lowerPriceX64, upperPriceX64, 0, 0);
  }

  /// @dev Pin exact outputs for inverted endpoint-mean pricing at max bin position.
  function test_maxPositionPoC_ethForUsdc_matchesCorrectedOutputs() public view {
    uint256[5] memory ethIns = [uint256(0.5e18), 1e18, 2e18, 3e18, 4e18];
    uint256[5] memory expectedUsdcOut = [
      uint256(997_482_614_469_667_210_784),
      uint256(1_994_915_502_744_258_022_365),
      uint256(3_989_632_100_710_805_364_900),
      uint256(5_984_149_793_908_538_062_048),
      uint256(7_978_468_582_352_287_614_023)
    ];

    for (uint256 i = 0; i < ethIns.length; i++) {
      assertEq(_swapEthForUsdc(ethIns[i]), expectedUsdcOut[i], "USDC out mismatch");
    }
  }

  /// @dev PoC table values are rounded to milli-USDC; stay within 0.001 USDC of each row.
  function test_maxPositionPoC_withinPoCTableTolerance() public view {
    uint256[5] memory ethIns = [uint256(0.5e18), 1e18, 2e18, 3e18, 4e18];
    uint256[5] memory pocMilliUsdc = [uint256(997_483), 1_994_916, 3_989_632, 5_984_150, 7_978_469];
    uint256 milliTolerance = 1e15; // 0.001 USDC at 18 decimals

    for (uint256 i = 0; i < ethIns.length; i++) {
      uint256 usdcOut = _swapEthForUsdc(ethIns[i]);
      uint256 pocScaled = pocMilliUsdc[i] * 1e15; // milli -> 18 decimals
      uint256 diff = usdcOut > pocScaled ? usdcOut - pocScaled : pocScaled - usdcOut;
      assertLe(diff, milliTolerance, "outside PoC table tolerance");
    }
  }

  /// @dev Guard against the pre-fix underpayment (~997.258 USDC for 0.5 ETH in).
  function test_maxPositionPoC_notUnderpaidLikeDeployed() public view {
    assertGt(_swapEthForUsdc(0.5e18), 997_400_000_000_000_000_000);
  }
}
