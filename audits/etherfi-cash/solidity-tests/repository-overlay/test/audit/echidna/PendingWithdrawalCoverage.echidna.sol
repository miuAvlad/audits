// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @notice Native Echidna state model for CashLens._idleBalance's reservation assumption.
 *
 * CashModule accepts a withdrawal only after checking that the Safe owns the requested amount.
 * CashLens later treats that amount as reserved and computes:
 *
 *     idle = looseBalance > pendingAmount ? looseBalance - pendingAmount : 0;
 *
 * The fork-based Foundry invariant is the authority for protocol operations. This small model only asks
 * which external token semantics can reduce old-token coverage without a Safe-mediated transfer:
 * standard fee-on-transfer, sender-extra-fee behavior, migration, privileged burn, and rebase.
 *
 * This is a transition model, not a replacement for the integration invariant in
 * test/safe/modules/cash/lend/CashFlowsInvariant.t.sol. The latter executes the real CashModule,
 * CashLens, EtherFiSafe and lending paths on a fork; this file gives native Echidna a small,
 * cheatcode-free target that can shrink only external-token counterexamples.
 */
contract PendingWithdrawalCoverageEchidna {
    uint256 private constant INITIAL_SAFE_BALANCE = 1_000_000e6;

    uint256 public safeBalance = INITIAL_SAFE_BALANCE;
    uint256 public pendingAmount;

    bool public cancellationFailed;
    bool public underfundedProcessSucceeded;

    uint256 public replacementTokenBalance;
    uint256 public feeRecipientBalance;
    bool public standardFeeTransferBrokeCoverage;
    bool public senderExtraFeeBrokeCoverage;
    bool public migrationBrokeCoverage;
    bool public privilegedBurnBrokeCoverage;
    bool public rebaseBrokeCoverage;

    /// Creates the same reservation precondition enforced by CashModule._checkBalance.
    function requestWithdrawal(uint96 amountSeed) external {
        if (pendingAmount != 0 || safeBalance == 0) return;

        pendingAmount = 1 + uint256(amountSeed) % safeBalance;
    }

    /// Models yield, a positive rebase or an inbound transfer to the Safe.
    function increaseSafeBalance(uint96 amountSeed) external {
        safeBalance += 1 + uint256(amountSeed);
    }

    /// Models successful processing of a still-covered request.
    function processWithdrawal() external {
        bool coveredBefore = _isCovered();
        if (pendingAmount == 0) return;
        if (!coveredBefore) return;

        safeBalance -= pendingAmount;
        pendingAmount = 0;

        // This flag would identify a model error where an underfunded request transferred funds.
        if (!coveredBefore) underfundedProcessSucceeded = true;
    }

    /// Models the owner-authorized CashModule cancellation path.
    function cancelWithdrawal() external {
        pendingAmount = 0;
        if (pendingAmount != 0) cancellationFailed = true;
    }

    /// Models ordinary fee-on-transfer behavior: the sender loses exactly the nominal amount while the
    /// receiver obtains less. Because the nominal spend is bounded to idle balance, reservation coverage
    /// must remain intact.
    function standardFeeOnTransfer(uint96 amountSeed, uint16 feeBpsSeed) external {
        bool coveredBefore = _isCovered();
        uint256 idle = _cashLensIdleBalance();
        if (idle == 0) return;

        uint256 nominal = 1 + uint256(amountSeed) % idle;
        uint256 feeBps = 1 + uint256(feeBpsSeed) % 5_000;
        uint256 fee = (nominal * feeBps) / 10_000;
        safeBalance -= nominal;
        feeRecipientBalance += fee;
        if (coveredBefore && !_isCovered()) standardFeeTransferBrokeCoverage = true;
    }

    /// Models a non-standard token that debits nominal + fee from the sender. Even when EtherFi limits
    /// nominal to idle balance, the extra debit can consume units reserved by a pending withdrawal.
    function senderExtraFeeTransfer(uint96 amountSeed, uint16 feeBpsSeed) external {
        bool coveredBefore = _isCovered();
        uint256 idle = _cashLensIdleBalance();
        if (idle == 0) return;

        uint256 nominal = 1 + uint256(amountSeed) % idle;
        uint256 feeBps = 1 + uint256(feeBpsSeed) % 5_000;
        uint256 extraFee = (nominal * feeBps + 9_999) / 10_000;
        if (nominal + extraFee > safeBalance) return;

        safeBalance -= nominal + extraFee;
        feeRecipientBalance += extraFee;
        if (coveredBefore && !_isCovered()) senderExtraFeeBrokeCoverage = true;
    }

    /// Models an external token migration that removes old-token units and credits a replacement token.
    /// The pending request remains denominated in the old token.
    function migrateTokenBalance() external {
        bool coveredBefore = _isCovered();
        if (safeBalance == 0) return;
        replacementTokenBalance += safeBalance;
        safeBalance = 0;
        if (coveredBefore && !_isCovered()) migrationBrokeCoverage = true;
    }

    /// Models a token-level privileged burn that does not execute a Safe transfer.
    function privilegedBurn(uint96 amountSeed) external {
        bool coveredBefore = _isCovered();
        if (safeBalance == 0) return;
        safeBalance -= 1 + uint256(amountSeed) % safeBalance;
        if (coveredBefore && !_isCovered()) privilegedBurnBrokeCoverage = true;
    }

    /**
     * Models a negative-rebase/slashing token. The Safe does not initiate a transfer, so neither
     * EtherFiSafe's hook nor CashModule can preserve or cancel the existing reservation first.
     */
    function negativeRebase(uint96 amountSeed) external {
        bool coveredBefore = _isCovered();
        if (safeBalance == 0) return;
        safeBalance -= 1 + uint256(amountSeed) % safeBalance;
        if (coveredBefore && !_isCovered()) rebaseBrokeCoverage = true;
    }

    /// Expected to fail in the external-token campaign. Rebase is excluded, so the counterexample
    /// must use sender-extra-fee behavior, migration, or privileged burn.
    function echidna_pending_is_always_covered() external view returns (bool) {
        return _isCovered();
    }

    /// Ordinary receiver-side fee-on-transfer semantics do not debit more than the idle nominal amount.
    function echidna_standard_fee_transfer_preserves_coverage() external view returns (bool) {
        return !standardFeeTransferBrokeCoverage;
    }

    /// These three properties intentionally fail independently and identify which external semantic can
    /// underfund a live old-token reservation.
    function echidna_sender_extra_fee_preserves_coverage() external view returns (bool) {
        return !senderExtraFeeBrokeCoverage;
    }

    function echidna_migration_preserves_old_token_coverage() external view returns (bool) {
        return !migrationBrokeCoverage;
    }

    function echidna_privileged_burn_preserves_coverage() external view returns (bool) {
        return !privilegedBurnBrokeCoverage;
    }

    /// With negativeRebase excluded from the function filter, this remains true and confirms that the
    /// campaign did not accidentally re-enable the already-known rebase cause.
    function echidna_rebase_is_excluded() external view returns (bool) {
        return !rebaseBrokeCoverage;
    }

    /// Every observed deficit must be attributable to one of the explicitly modeled token semantics.
    function echidna_every_deficit_is_attributed() external view returns (bool) {
        if (_isCovered()) return true;
        return senderExtraFeeBrokeCoverage || migrationBrokeCoverage || privilegedBurnBrokeCoverage || rebaseBrokeCoverage;
    }

    /// Processing must refuse an underfunded reservation rather than partially transferring it.
    function echidna_underfunded_processing_never_succeeds() external view returns (bool) {
        return !underfundedProcessSucceeded;
    }

    /// Cancellation is state recovery even if token semantics have already underfunded the request.
    function echidna_cancellation_clears_request() external view returns (bool) {
        return !cancellationFailed;
    }

    /// Mirrors the exact clamp in CashLens._idleBalance and checks both branches explicitly.
    function echidna_idle_balance_matches_cash_lens_clamp() external view returns (bool) {
        uint256 idle = _cashLensIdleBalance();
        if (safeBalance <= pendingAmount) return idle == 0;
        return idle == safeBalance - pendingAmount;
    }

    function _cashLensIdleBalance() internal view returns (uint256) {
        return safeBalance > pendingAmount ? safeBalance - pendingAmount : 0;
    }

    function _isCovered() internal view returns (bool) {
        return pendingAmount == 0 || pendingAmount <= safeBalance;
    }
}
