// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MetricOmmPoolBaseTest} from "./MetricOmmPool.base.t.sol";
import {PoolStateTestLib} from "./PoolStateTestLib.sol";
import {PoolStateLibrary} from "../contracts/libraries/PoolStateLibrary.sol";
import {BinState} from "../contracts/types/PoolStorage.sol";
import {LiquidityDelta} from "../contracts/types/PoolOperation.sol";

/// @notice Fuzzes the invariant linking the active bin index to its cumulative distance from the oracle mid.
contract MetricOmmPoolCursorDistanceInvariantAuditTest is MetricOmmPoolBaseTest {
  uint256 internal constant CURSOR_Q64 = 1 << 64;
  int24 internal constant INITIAL_DISTANCE_E6 = -12_347;
  int8 internal constant LOWEST_TEST_BIN = -5;
  int8 internal constant HIGHEST_TEST_BIN = 4;
  uint104 internal constant SHARES_PER_LIQUID_BIN = 100e18;
  uint256 internal constant SWAPPER = 0;
  uint256 internal constant LP = 1;

  function setUp() public override {
    super.setUp();

    (BinState[] memory nonNegative, BinState[] memory negative) = _variableWidthBins();
    pool = _deployPoolAndRegister(
      PoolDeployParams({
        priceProvider: address(oracle),
        extensions: _emptyExtensions(),
        extensionOrders: _emptyExtensionOrders(),
        immutablePriceProvider: true,
        protocolSpreadFeeE6: PROTOCOL_FEE,
        adminSpreadFeeE6: ADMIN_FEE,
        curBinDistFromProvidedPriceE6: INITIAL_DISTANCE_E6,
        nonNegativeBinStates: nonNegative,
        negativeBinStates: negative,
        protocolNotionalFeeE8: 0,
        adminNotionalFeeE8: 0,
        immutablePriceProviderForRegistry: address(oracle),
        lowestBin: LOWEST_TEST_BIN,
        highestBin: HIGHEST_TEST_BIN
      })
    );
    _approveUsersForPool(address(pool));
    _seedNonContiguousLiquidity();
    _assertCursorDistanceInvariant();
  }

  function testFuzz_cursorDistanceMatchesAfterArbitrarySwapSequence(uint256 seed, uint8 rawSteps) public {
    uint256 steps = bound(uint256(rawSteps), 1, 48);

    for (uint256 i; i < steps; i++) {
      uint256 entropy = uint256(keccak256(abi.encode(seed, i)));
      _setFuzzOracle(entropy);
      _assertCursorDistanceInvariant();

      bool zeroForOne = entropy & 1 == 0;
      bool exactOutput = entropy & 2 != 0;
      uint128 amount = uint128(1 + ((entropy >> 8) % 250e18));
      int128 amountSpecified = exactOutput ? _i128ExactOut(amount) : _i128ExactIn(amount);

      _trySwap(zeroForOne, amountSpecified);
      _assertCursorDistanceInvariant();
    }
  }

  function test_crossesEmptyVariableWidthBinUpwardAndPreservesDistance() public {
    _swapOnPool(address(pool), SWAPPER, address(callers[SWAPPER]), false, _i128ExactOut(150e18), type(uint128).max);

    assertEq(PoolStateTestLib.curBinIdx(address(pool)), 2, "upward swap did not cross empty bin 1");
    _assertCursorDistanceInvariant();
  }

  function test_crossesEmptyVariableWidthBinDownwardAndPreservesDistance() public {
    _swapOnPool(address(pool), SWAPPER, address(callers[SWAPPER]), true, _i128ExactOut(50e18), 0);

    assertEq(PoolStateTestLib.curBinIdx(address(pool)), -2, "downward swap did not cross empty bin -1");
    _assertCursorDistanceInvariant();
  }

  function _trySwap(bool zeroForOne, int128 amountSpecified) internal {
    vm.prank(users[SWAPPER]);
    try callers[SWAPPER].swap(
      address(pool), address(callers[SWAPPER]), zeroForOne, amountSpecified, zeroForOne ? 0 : type(uint128).max
    ) returns (
      int256, int256
    ) {}
      catch {}
  }

  function _assertCursorDistanceInvariant() internal view {
    (, int8 currentBin,, int24 storedDistanceE6,,) = PoolStateLibrary._slot0(address(pool));
    int256 expectedDistanceE6 = _expectedDistanceFor(currentBin);
    assertEq(int256(storedDistanceE6), expectedDistanceE6, "bin index and stored distance diverged");

    for (int256 bin = int256(LOWEST_TEST_BIN); bin <= int256(HIGHEST_TEST_BIN); bin++) {
      int8 binIdx = int8(bin);
      assertEq(_binLength(binIdx), _configuredBinLength(binIdx), "stored bin length changed");
    }

    if (currentBin < HIGHEST_TEST_BIN) {
      int256 currentUpperDistanceE6 = int256(storedDistanceE6) + int256(uint256(_configuredBinLength(currentBin)));
      assertEq(
        currentUpperDistanceE6,
        _expectedDistanceFor(currentBin + 1),
        "current upper boundary does not equal next lower boundary"
      );
    }

    if (currentBin > LOWEST_TEST_BIN) {
      int8 previousBin = currentBin - 1;
      int256 previousUpperDistanceE6 =
        _expectedDistanceFor(previousBin) + int256(uint256(_configuredBinLength(previousBin)));
      assertEq(
        previousUpperDistanceE6,
        int256(storedDistanceE6),
        "previous upper boundary does not equal current lower boundary"
      );
    }
  }

  function _expectedDistanceFor(int8 targetBin) internal view returns (int256 expectedDistanceE6) {
    expectedDistanceE6 = int256(INITIAL_DISTANCE_E6);

    if (targetBin > 0) {
      for (int256 bin; bin < int256(targetBin); bin++) {
        expectedDistanceE6 += int256(uint256(_configuredBinLength(int8(bin))));
      }
    } else {
      for (int256 bin = -1; bin >= int256(targetBin); bin--) {
        expectedDistanceE6 -= int256(uint256(_configuredBinLength(int8(bin))));
      }
    }
  }

  function _binLength(int8 bin) internal view returns (uint16 lengthE6) {
    (,, lengthE6,,) = PoolStateTestLib.binState(address(pool), bin);
  }

  function _configuredBinLength(int8 bin) internal pure returns (uint16) {
    if (bin == -5) return 11_111;
    if (bin == -4) return 18_765;
    if (bin == -3) return 6_789;
    if (bin == -2) return 14_321;
    if (bin == -1) return 8_765;
    if (bin == 0) return 7_111;
    if (bin == 1) return 12_345;
    if (bin == 2) return 5_432;
    if (bin == 3) return 22_222;
    if (bin == 4) return 9_999;
    revert("unconfigured bin");
  }

  function _setFuzzOracle(uint256 entropy) internal {
    uint256 midX64 = (CURSOR_Q64 * (900_000 + (entropy % 200_001))) / 1e6;
    uint256 halfSpreadX64 = 1 + midX64 / 100_000;
    oracle.setBidAndAskPrice(uint128(midX64 - halfSpreadX64), uint128(midX64 + halfSpreadX64));
  }

  function _seedNonContiguousLiquidity() internal {
    int256[7] memory liquidBins = [int256(-5), int256(-3), int256(-2), int256(0), int256(2), int256(3), int256(4)];
    LiquidityDelta memory deltas;
    deltas.binIdxs = new int256[](liquidBins.length);
    deltas.shares = new uint256[](liquidBins.length);

    for (uint256 i; i < liquidBins.length; i++) {
      deltas.binIdxs[i] = liquidBins[i];
      deltas.shares[i] = SHARES_PER_LIQUID_BIN;
    }

    vm.prank(users[LP]);
    callers[LP].addLiquidity(address(pool), 1, deltas);
  }

  function _variableWidthBins() internal pure returns (BinState[] memory nonNegative, BinState[] memory negative) {
    nonNegative = new BinState[](5);
    negative = new BinState[](5);

    nonNegative[0] = _emptyBin(7_111);
    nonNegative[1] = _emptyBin(12_345);
    nonNegative[2] = _emptyBin(5_432);
    nonNegative[3] = _emptyBin(22_222);
    nonNegative[4] = _emptyBin(9_999);

    negative[0] = _emptyBin(8_765);
    negative[1] = _emptyBin(14_321);
    negative[2] = _emptyBin(6_789);
    negative[3] = _emptyBin(18_765);
    negative[4] = _emptyBin(11_111);
  }

  function _emptyBin(uint16 lengthE6) internal pure returns (BinState memory) {
    return
      BinState({token0BalanceScaled: 0, token1BalanceScaled: 0, lengthE6: lengthE6, addFeeBuyE6: 0, addFeeSellE6: 0});
  }
}
