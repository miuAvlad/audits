// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MetricOmmPoolBaseTest} from "./MetricOmmPool.base.t.sol";
import {IMetricOmmPoolActions} from "../contracts/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {PoolImmutables} from "../contracts/interfaces/IMetricOmmPool/IMetricOmmPool.sol";
import {LiquidityDelta} from "../contracts/types/PoolOperation.sol";

contract MetricOmmPoolRemoveLiquidityFuzzTest is MetricOmmPoolBaseTest {
  uint256 internal constant USER_INDEX = 0;
  uint256 internal constant MAX_FUZZ_SHARES = 1e18;

  function testFuzz_removeLiquidity_validSingleBin_noUnderflow(
    int256 rawBin,
    uint80 salt,
    uint256 rawSharesToAdd,
    uint256 rawSharesToRemove
  ) public {
    int8 bin = _boundBin(rawBin);
    uint256 sharesToAdd = _boundUint(rawSharesToAdd, MINIMAL_MINTABLE_LIQUIDITY, MAX_FUZZ_SHARES);
    uint256 sharesToRemove = _validSharesToRemove(rawSharesToRemove, sharesToAdd);

    _addLiquidityDelta(salt, _makeDelta1(bin, sharesToAdd));

    (uint256 total0Before, uint256 total1Before) = _scaledTotals();
    uint256 binSharesBefore = _getBinTotalShares(bin);

    _removeLiquidityDelta(salt, _makeDelta1(bin, sharesToRemove));

    (uint256 total0After, uint256 total1After) = _scaledTotals();
    assertLe(total0After, total0Before, "token0 scaled total increased on remove");
    assertLe(total1After, total1Before, "token1 scaled total increased on remove");
    assertEq(_getBinTotalShares(bin), binSharesBefore - sharesToRemove, "wrong bin total shares");

    uint256 remainingShares = _positionShares(salt, bin);
    assertEq(remainingShares, sharesToAdd - sharesToRemove, "wrong remaining shares");
  }

  function testFuzz_removeLiquidity_duplicateSameBin_validSplit_noUnderflow(
    int256 rawBin,
    uint80 salt,
    uint256 rawSharesToAdd,
    uint256 rawTotalRemove,
    uint256 rawSplit
  ) public {
    int8 bin = _boundBin(rawBin);
    uint256 sharesToAdd = _boundUint(rawSharesToAdd, MINIMAL_MINTABLE_LIQUIDITY * 2, MAX_FUZZ_SHARES);
    (uint256 firstRemove, uint256 secondRemove) = _validDuplicateRemoveSplit(rawTotalRemove, rawSplit, sharesToAdd);
    uint256 totalRemove = firstRemove + secondRemove;

    _addLiquidityDelta(salt, _makeDelta1(bin, sharesToAdd));
    _removeLiquidityDelta(salt, _makeDelta2SameBin(bin, firstRemove, secondRemove));

    uint256 remainingShares = _positionShares(salt, bin);
    assertEq(remainingShares, sharesToAdd - totalRemove, "wrong remaining shares after duplicate-bin remove");
    assertEq(_getBinTotalShares(bin), sharesToAdd - totalRemove, "wrong bin total shares after duplicate-bin remove");
  }

  function testFuzz_removeLiquidity_duplicateSameBin_overRemoveRevertsWithoutPanic(
    int256 rawBin,
    uint80 salt,
    uint256 rawSharesToAdd,
    uint256 rawSecondRemove
  ) public {
    int8 bin = _boundBin(rawBin);
    uint256 sharesToAdd = _boundUint(rawSharesToAdd, MINIMAL_MINTABLE_LIQUIDITY, MAX_FUZZ_SHARES);
    uint256 secondRemove = _boundUint(rawSecondRemove, 1, sharesToAdd);

    _addLiquidityDelta(salt, _makeDelta1(bin, sharesToAdd));

    LiquidityDelta memory removeDelta = _makeDelta2SameBin(bin, sharesToAdd, secondRemove);
    vm.prank(users[USER_INDEX]);
    try callers[USER_INDEX].removeLiquidity(address(pool), salt, removeDelta) returns (uint256, uint256) {
      fail("duplicate-bin over-remove unexpectedly succeeded");
    } catch Panic(uint256) {
      fail("duplicate-bin over-remove reverted with Panic");
    } catch (bytes memory reason) {
      assertEq(
        _selector(reason),
        IMetricOmmPoolActions.InsufficientLiquidity.selector,
        "wrong duplicate-bin over-remove revert selector"
      );
    }
  }

  function testFuzz_removeLiquidity_duplicateSameBin_fullRemoveViaDustSplit_revertsWithMinimalLiquidity(
    int256 rawBin,
    uint80 salt,
    uint256 rawSharesToAdd,
    uint256 rawDustRemaining
  ) public {
    int8 bin = _boundBin(rawBin);
    uint256 sharesToAdd = _boundUint(rawSharesToAdd, MINIMAL_MINTABLE_LIQUIDITY + 1, MAX_FUZZ_SHARES);
    uint256 dustRemaining = _boundUint(rawDustRemaining, 1, MINIMAL_MINTABLE_LIQUIDITY - 1);
    uint256 firstRemove = sharesToAdd - dustRemaining;
    uint256 secondRemove = dustRemaining;

    _addLiquidityDelta(salt, _makeDelta1(bin, sharesToAdd));

    vm.expectRevert(
      abi.encodeWithSelector(
        IMetricOmmPoolActions.MinimalLiquidity.selector, dustRemaining, uint256(MINIMAL_MINTABLE_LIQUIDITY)
      )
    );
    _removeLiquidityDelta(salt, _makeDelta2SameBin(bin, firstRemove, secondRemove));
  }

  function _addLiquidityDelta(uint80 salt, LiquidityDelta memory delta) internal returns (uint256, uint256) {
    vm.prank(users[USER_INDEX]);
    return callers[USER_INDEX].addLiquidity(address(pool), salt, delta);
  }

  function _removeLiquidityDelta(uint80 salt, LiquidityDelta memory delta) internal returns (uint256, uint256) {
    vm.prank(users[USER_INDEX]);
    return callers[USER_INDEX].removeLiquidity(address(pool), salt, delta);
  }

  function _makeDelta1(int8 bin, uint256 shares) internal pure returns (LiquidityDelta memory delta) {
    int256[] memory bins = new int256[](1);
    uint256[] memory sharesArr = new uint256[](1);
    bins[0] = bin;
    sharesArr[0] = shares;
    delta = LiquidityDelta({binIdxs: bins, shares: sharesArr});
  }

  function _makeDelta2SameBin(int8 bin, uint256 shares0, uint256 shares1)
    internal
    pure
    returns (LiquidityDelta memory delta)
  {
    int256[] memory bins = new int256[](2);
    uint256[] memory sharesArr = new uint256[](2);
    bins[0] = bin;
    bins[1] = bin;
    sharesArr[0] = shares0;
    sharesArr[1] = shares1;
    delta = LiquidityDelta({binIdxs: bins, shares: sharesArr});
  }

  function _boundBin(int256 rawBin) internal view returns (int8) {
    PoolImmutables memory immutables = pool.getImmutables();
    int256 lowest = immutables.lowestBin;
    int256 highest = immutables.highestBin;
    uint256 span = uint256(highest - lowest + 1);
    uint256 offset = uint256(keccak256(abi.encode(rawBin))) % span;
    return int8(lowest + int256(offset));
  }

  function _validSharesToRemove(uint256 seed, uint256 sharesToAdd) internal pure returns (uint256) {
    if (sharesToAdd <= MINIMAL_MINTABLE_LIQUIDITY) return sharesToAdd;
    if (seed % 4 == 0) return sharesToAdd;
    return _boundUint(seed, 1, sharesToAdd - MINIMAL_MINTABLE_LIQUIDITY);
  }

  function _validDuplicateRemoveSplit(uint256 totalSeed, uint256 splitSeed, uint256 sharesToAdd)
    internal
    pure
    returns (uint256 firstRemove, uint256 secondRemove)
  {
    uint256 totalRemove;
    if (totalSeed % 4 == 0) {
      totalRemove = sharesToAdd;
      firstRemove = _boundUint(splitSeed, 1, sharesToAdd - MINIMAL_MINTABLE_LIQUIDITY);
    } else {
      totalRemove = _boundUint(totalSeed, 2, sharesToAdd - MINIMAL_MINTABLE_LIQUIDITY);
      firstRemove = _boundUint(splitSeed, 1, totalRemove - 1);
    }
    secondRemove = totalRemove - firstRemove;
  }

  function _positionShares(uint80 salt, int8 bin) internal view returns (uint256) {
    return _getPositionBinShares(_getCallerAddress(USER_INDEX), salt, bin);
  }

  function _scaledTotals() internal view returns (uint256 total0, uint256 total1) {
    PoolImmutables memory immutables = pool.getImmutables();
    for (int256 bin = immutables.lowestBin; bin <= immutables.highestBin; bin++) {
      (uint104 token0BalanceScaled, uint104 token1BalanceScaled,,,) = _getBinState(int8(bin));
      total0 += token0BalanceScaled;
      total1 += token1BalanceScaled;
    }
  }

  function _selector(bytes memory reason) internal pure returns (bytes4 selector) {
    if (reason.length < 4) return bytes4(0);
    assembly ("memory-safe") {
      selector := mload(add(reason, 32))
    }
  }

  function _boundUint(uint256 value, uint256 min, uint256 max) internal pure returns (uint256) {
    if (min == max) return min;
    return min + (value % (max - min + 1));
  }
}
