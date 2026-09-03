// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {console2} from "forge-std/console2.sol";
import {MetricOmmPoolBaseTest} from "./MetricOmmPool.base.t.sol";
import {MetricOmmPool} from "../contracts/MetricOmmPool.sol";
import {BinState} from "../contracts/types/PoolStorage.sol";

/// @notice Differential check for the two notional-fee formulas used by exact-in and exact-out swaps.
contract MetricOmmPoolNotionalFeeModeAuditTest is MetricOmmPoolBaseTest {
  uint24 internal constant ONE_PERCENT_E8 = 1_000_000;
  uint24 internal constant TOTAL_NOTIONAL_FEE_E8 = 2 * ONE_PERCENT_E8;

  MetricOmmPool internal exactInputPool;
  MetricOmmPool internal exactOutputPool;

  function setUp() public override {
    super.setUp();

    exactInputPool = _deployFeePool();
    exactOutputPool = _deployFeePool();
    _approveUsersForPool(address(exactInputPool));
    _approveUsersForPool(address(exactOutputPool));

    // Keep price impact small so the measured difference is dominated by the fee-mode formulas.
    _addLiquidityOn(address(exactInputPool), 1, -5, 4, 100_000e18, 0);
    _addLiquidityOn(address(exactOutputPool), 1, -5, 4, 100_000e18, 0);
  }

  function test_exactOutputPaysLessThanEquivalentExactInputAtSameConfiguredRate() public {
    uint128 targetOutput = 1e18;

    // Exact output pays a notional fee on the fee-exclusive input: baseInput * (1 + f).
    (int256 exactOutDelta0, int256 exactOutDelta1) =
      _swapOnPool(address(exactOutputPool), 0, users[0], false, -int128(targetOutput), type(uint128).max);
    assertEq(uint256(-exactOutDelta0), targetOutput, "exact-output target must be filled");
    uint128 exactOutputInput = uint128(uint256(exactOutDelta1));

    // Spend that exact same input through the exact-input API. Its fee is removed from output,
    // so obtaining Q net output requires grossing up by 1 / (1 - f), not multiplying by 1 + f.
    (int256 exactInDelta0, int256 exactInDelta1) = _swapOnPool(
      address(exactInputPool), 0, users[0], false, int128(exactOutputInput), type(uint128).max
    );
    assertEq(uint256(exactInDelta1), exactOutputInput, "both swaps spend the same input");
    uint256 exactInputOutput = uint256(-exactInDelta0);

    uint256 outputShortfall = uint256(targetOutput) - exactInputOutput;
    uint256 shortfallBpsE4 = outputShortfall * 1e8 / targetOutput;

    console2.log("configured notional fee (bps):", uint256(TOTAL_NOTIONAL_FEE_E8) / 1e4);
    console2.log("target output:", targetOutput);
    console2.log("input paid by exact-output:", exactOutputInput);
    console2.log("output from same exact-input amount:", exactInputOutput);
    console2.log("exact-input output shortfall:", outputShortfall);
    console2.log("shortfall (bps x 1e4):", shortfallBpsE4);

    assertGt(outputShortfall, 0, "exact-output should be cheaper under the current formulas");
    // At f = 2%, the formula-only discrepancy is f^2 / (1-f) = about 4.0816 bps.
    assertGt(shortfallBpsE4, 3e4, "gap should exceed three basis points");
    assertLt(shortfallBpsE4, 6e4, "small trade should stay near the expected four-bps gap");
  }

  function _deployFeePool() internal returns (MetricOmmPool deployedPool) {
    (BinState[] memory nonNegativeBinStates, BinState[] memory negativeBinStates) = _defaultBinStateArrays();
    deployedPool = _deployPoolAndRegister(
      PoolDeployParams({
        priceProvider: address(oracle),
        extensions: _emptyExtensions(),
        extensionOrders: _emptyExtensionOrders(),
        immutablePriceProvider: true,
        protocolSpreadFeeE6: 0,
        adminSpreadFeeE6: 0,
        curBinDistFromProvidedPriceE6: 0,
        nonNegativeBinStates: nonNegativeBinStates,
        negativeBinStates: negativeBinStates,
        protocolNotionalFeeE8: ONE_PERCENT_E8,
        adminNotionalFeeE8: ONE_PERCENT_E8,
        immutablePriceProviderForRegistry: address(oracle),
        lowestBin: -1,
        highestBin: 0
      })
    );
  }

  function _addLiquidityOn(address poolAddr, uint256 userIndex, int8 lo, int8 hi, uint104 shares, uint80 salt)
    internal
  {
    vm.prank(users[userIndex]);
    callers[userIndex].addLiquidity(poolAddr, salt, _rangeDeltas(lo, hi, shares));
  }
}
