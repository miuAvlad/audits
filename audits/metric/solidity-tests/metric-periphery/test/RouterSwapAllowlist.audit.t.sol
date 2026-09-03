// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MetricOmmPool} from "@metric-core/MetricOmmPool.sol";
import {IMetricOmmPoolActions} from "@metric-core/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {PoolFeeConfig} from "@metric-core/types/FactoryStorage.sol";
import {PoolExtensions, ExtensionOrders} from "@metric-core/types/PoolExtensionsConfig.sol";
import {BinState} from "@metric-core/types/PoolStorage.sol";
import {SwapAllowlistExtension} from "../contracts/extensions/SwapAllowlistExtension.sol";
import {IMetricOmmSimpleRouter} from "../contracts/interfaces/IMetricOmmSimpleRouter.sol";
import {SimpleRouterTestBase} from "./helpers/SimpleRouterTestBase.sol";

contract RouterSwapAllowlistAuditTest is SimpleRouterTestBase {
  SwapAllowlistExtension internal swapAllowlist;
  MetricOmmPool internal allowlistedPool;
  address internal unlistedUser;

  function setUp() public override {
    super.setUp();

    swapAllowlist = new SwapAllowlistExtension(address(factoryStub));
    allowlistedPool = _deployAllowlistedPool();
    _seedLiquidityPool(allowlistedPool, address(weth), address(token1), 2);

    unlistedUser = makeAddr("unlisted router user");
    vm.deal(unlistedUser, 1 ether);
    vm.startPrank(unlistedUser);
    weth.deposit{value: 1 ether}();
    weth.approve(address(router), type(uint256).max);
    vm.stopPrank();
  }

  function test_allowlistingRouterAuthorizesEveryRouterCaller() public {
    uint128 amountIn = 1_000;

    // Allowlisting the end user does not authorize their routed swap because
    // the pool forwards its direct caller, the router, as `sender`.
    swapAllowlist.setAllowedToSwap(address(allowlistedPool), unlistedUser, true);
    vm.prank(unlistedUser);
    vm.expectRevert(IMetricOmmPoolActions.NotAllowedToSwap.selector);
    router.exactInputSingle(_swapParams(amountIn));

    // Conversely, once the router is allowed, the extension cannot distinguish
    // this user from any other caller of the permissionless router.
    swapAllowlist.setAllowedToSwap(address(allowlistedPool), unlistedUser, false);
    swapAllowlist.setAllowedToSwap(address(allowlistedPool), address(router), true);
    assertFalse(swapAllowlist.isAllowedToSwap(address(allowlistedPool), unlistedUser));

    uint256 balanceBefore = token1.balanceOf(unlistedUser);
    vm.prank(unlistedUser);
    uint256 amountOut = router.exactInputSingle(_swapParams(amountIn));

    assertGt(amountOut, 0, "unlisted caller received no output");
    assertEq(token1.balanceOf(unlistedUser) - balanceBefore, amountOut);
  }

  function _swapParams(uint128 amountIn)
    internal
    view
    returns (IMetricOmmSimpleRouter.ExactInputSingleParams memory params)
  {
    params = IMetricOmmSimpleRouter.ExactInputSingleParams({
      pool: address(allowlistedPool),
      tokenIn: address(weth),
      tokenOut: address(token1),
      zeroForOne: true,
      amountIn: amountIn,
      amountOutMinimum: 0,
      recipient: unlistedUser,
      deadline: _deadline(),
      priceLimitX64: 0,
      extensionData: ""
    });
  }

  function _deployAllowlistedPool() internal returns (MetricOmmPool deployed) {
    (uint256[] memory nnPacked, uint256[] memory negPacked) = _binPackedArrays();
    (BinState[] memory nnStates, BinState[] memory negStates) = _unpackBinStates(nnPacked, negPacked);
    (uint256 token0ScaleMultiplier, uint256 token1ScaleMultiplier) =
      _getScaleMultipliers(address(weth), address(token1));

    PoolExtensions memory extensions;
    extensions.extension1 = address(swapAllowlist);
    ExtensionOrders memory extensionOrders;
    extensionOrders.beforeSwap = 1;

    address adminFeeDestination = makeAddr("allowlisted pool admin fee destination");
    deployed = new MetricOmmPool(
      address(factoryStub),
      address(this),
      adminFeeDestination,
      address(weth),
      address(token1),
      address(oracle),
      extensions,
      extensionOrders,
      true,
      token0ScaleMultiplier,
      token1ScaleMultiplier,
      INITIAL_TOKEN_0_DENSITY,
      INITIAL_TOKEN_1_DENSITY,
      MINIMAL_MINTABLE_LIQUIDITY,
      PROTOCOL_FEE + ADMIN_FEE,
      0,
      nnStates,
      negStates,
      0
    );

    factoryStub.registerPool(
      address(deployed),
      PoolFeeConfig({
        protocolSpreadFeeE6: PROTOCOL_FEE, adminSpreadFeeE6: ADMIN_FEE, protocolNotionalFeeE8: 0, adminNotionalFeeE8: 0
      }),
      adminFeeDestination,
      address(this)
    );
  }
}
