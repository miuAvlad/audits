// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MetricOmmPoolBaseTest} from "./MetricOmmPool.base.t.sol";
import {MetricOmmPool} from "../contracts/MetricOmmPool.sol";
import {BinState} from "../contracts/types/PoolStorage.sol";
import {PoolStateTestLib} from "./PoolStateTestLib.sol";

/// @notice Audit regression checks for amplification through split swaps at bin boundaries.
/// @dev Identical pools execute one aggregate swap versus the same swap split across multiple calls.
contract MetricOmmPoolSplitBoundaryAuditTest is MetricOmmPoolBaseTest {
  uint256 internal constant SWAPPER = 0;
  uint256 internal constant LP = 1;
  uint104 internal constant SHARES_PER_BIN = 1e18;

  MetricOmmPool internal oneShotPool;
  MetricOmmPool internal splitPool;

  function setUp() public override {
    super.setUp();
    oneShotPool = pool;

    (BinState[] memory nonNegative, BinState[] memory negative) = _defaultBinStateArrays();
    splitPool = _deployPoolAndRegister(
      PoolDeployParams({
        priceProvider: address(oracle),
        extensions: _emptyExtensions(),
        extensionOrders: _emptyExtensionOrders(),
        immutablePriceProvider: true,
        protocolSpreadFeeE6: PROTOCOL_FEE,
        adminSpreadFeeE6: ADMIN_FEE,
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
    _approveUsersForPool(address(splitPool));

    pool = oneShotPool;
    _addLiquidity(LP, -5, 4, SHARES_PER_BIN, 1);
    pool = splitPool;
    _addLiquidity(LP, -5, 4, SHARES_PER_BIN, 1);
  }

  function testFuzz_splitExactInputDoesNotExtractMoreAcrossBins(uint128 rawAmount, uint8 rawParts, bool zeroForOne)
    public
  {
    uint128 amount = uint128(bound(rawAmount, 1e15, 35e17));
    uint8 parts = uint8(bound(rawParts, 2, 64));

    if (zeroForOne) _seedBothPoolsForDownwardSwap();

    (int256 oneDelta0, int256 oneDelta1) = _swapOnPool(
      address(oneShotPool),
      SWAPPER,
      address(callers[SWAPPER]),
      zeroForOne,
      _i128ExactIn(amount),
      zeroForOne ? 0 : type(uint128).max
    );
    uint256 oneOutput = uint256(-(zeroForOne ? oneDelta1 : oneDelta0));

    uint256 splitOutput;
    uint256 remaining = amount;
    for (uint256 i; i < parts; ++i) {
      uint256 part = i + 1 == parts ? remaining : uint256(amount) / parts;
      remaining -= part;
      (int256 delta0, int256 delta1) = _swapOnPool(
        address(splitPool),
        SWAPPER,
        address(callers[SWAPPER]),
        zeroForOne,
        _i128ExactIn(uint128(part)),
        zeroForOne ? 0 : type(uint128).max
      );
      splitOutput += uint256(-(zeroForOne ? delta1 : delta0));
    }

    // A solver/cursor rounding difference may exist, but it must remain economically negligible.
    if (splitOutput > oneOutput) {
      uint256 gain = splitOutput - oneOutput;
      assertLt(gain * 1e8, oneOutput, "split exact-input gain reached 1e-8 of output");
    }
    _assertCursorDifferenceBounded(parts);
  }

  function testFuzz_splitExactOutputDoesNotReduceInputAcrossBins(uint128 rawAmount, uint8 rawParts, bool zeroForOne)
    public
  {
    uint128 amount = uint128(bound(rawAmount, 1e15, 35e17));
    uint8 parts = uint8(bound(rawParts, 2, 64));

    if (zeroForOne) _seedBothPoolsForDownwardSwap();

    (int256 oneDelta0, int256 oneDelta1) = _swapOnPool(
      address(oneShotPool),
      SWAPPER,
      address(callers[SWAPPER]),
      zeroForOne,
      _i128ExactOut(amount),
      zeroForOne ? 0 : type(uint128).max
    );
    uint256 oneInput = uint256(zeroForOne ? oneDelta0 : oneDelta1);
    uint256 oneOutput = uint256(-(zeroForOne ? oneDelta1 : oneDelta0));
    assertEq(oneOutput, amount, "one-shot exact output unexpectedly partial-filled");

    uint256 splitInput;
    uint256 splitOutput;
    uint256 remaining = amount;
    for (uint256 i; i < parts; ++i) {
      uint256 part = i + 1 == parts ? remaining : uint256(amount) / parts;
      remaining -= part;
      (int256 delta0, int256 delta1) = _swapOnPool(
        address(splitPool),
        SWAPPER,
        address(callers[SWAPPER]),
        zeroForOne,
        _i128ExactOut(uint128(part)),
        zeroForOne ? 0 : type(uint128).max
      );
      splitInput += uint256(zeroForOne ? delta0 : delta1);
      splitOutput += uint256(-(zeroForOne ? delta1 : delta0));
    }

    assertEq(splitOutput, amount, "split exact output unexpectedly partial-filled");
    if (splitInput < oneInput) {
      uint256 saving = oneInput - splitInput;
      assertLt(saving * 1e8, oneInput, "split exact-output saving reached 1e-8 of input");
    }
    _assertCursorDifferenceBounded(parts);
  }

  function _seedBothPoolsForDownwardSwap() internal {
    uint128 seed = 4e18;
    _swapOnPool(address(oneShotPool), SWAPPER, address(callers[SWAPPER]), false, _i128ExactIn(seed), type(uint128).max);
    _swapOnPool(address(splitPool), SWAPPER, address(callers[SWAPPER]), false, _i128ExactIn(seed), type(uint128).max);
  }

  function _assertCursorDifferenceBounded(uint256) internal view {
    int8 oneBin = PoolStateTestLib.curBinIdx(address(oneShotPool));
    int8 splitBin = PoolStateTestLib.curBinIdx(address(splitPool));
    assertEq(splitBin, oneBin, "splitting ended in a different bin");

    uint256 onePos = PoolStateTestLib.curPosInBin(address(oneShotPool));
    uint256 splitPos = PoolStateTestLib.curPosInBin(address(splitPool));
    uint256 positionDiff = onePos > splitPos ? onePos - splitPos : splitPos - onePos;
    assertLt(positionDiff * 1e8, uint256(type(uint104).max), "split cursor divergence reached 1e-8 of a bin");
  }
}
