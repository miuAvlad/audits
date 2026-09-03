// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Test } from "forge-std/Test.sol";

import { BinSponsor, Cashback, ICashModule, Mode, SafeData, WithdrawalRequest } from "../../../../../src/interfaces/ICashModule.sol";
import { CashVerificationLib } from "../../../../../src/libraries/CashVerificationLib.sol";
import { IBridgeModule } from "../../../../../src/interfaces/IBridgeModule.sol";
import { IEtherFiSafe } from "../../../../../src/interfaces/IEtherFiSafe.sol";
import { CashLens } from "../../../../../src/modules/cash/CashLens.sol";
import { ModuleBase } from "../../../../../src/modules/ModuleBase.sol";
import { ModuleCheckBalance } from "../../../../../src/modules/ModuleCheckBalance.sol";
import { LendGateway } from "../../../../../src/modules/lend-gateway/LendGateway.sol";
import { CashGatewayTestSetup } from "./CashGatewayTestSetup.t.sol";

/**
 * @title CashFlowsHandler
 * @notice Drives random sequences of module-level cash flows (card spends in both modes, withdrawal
 *         requests and cancellations, mode toggles, lend opt-out toggles, gateway ops, interest accrual)
 *         for the invariant campaign. Amounts are bounded to mostly succeed; residual reverts are
 *         tolerated (fail_on_revert=false), so property violations are recorded in ghost counters the
 *         invariants assert on — a revert inside the handler would otherwise be silently swallowed.
 * @dev Signature-gated flows go through the parent test's wrappers (the owner keys live there). The
 *      cumulative warp is capped: past oracle staleness every price read reverts and the campaign would
 *      go silently vacuous under revert tolerance.
 */
contract CashFlowsHandler is Test {
    ICashModule internal immutable cashModule;
    CashLens internal immutable cashLens;
    LendGateway internal immutable gw;
    address internal immutable safe;
    address internal immutable etherFiWallet;
    address internal immutable recipient;
    address internal immutable dispatcher;
    IERC20 internal immutable weeth;
    IERC20 internal immutable usdc;
    CashFlowsInvariantTest internal immutable parent;
    InvariantWithdrawalModule internal immutable withdrawalModule;
    InvariantBalanceCheckedModule internal immutable balanceCheckedModule;

    Cashback[] internal noCashback;
    uint256 internal txNonce;

    // Per-family success counters (vacuity guards)
    uint256 public opsGateway;
    uint256 public opsSpend;
    uint256 public opsWithdrawalFlow;
    uint256 public opsModeToggle;
    uint256 public opsOptOutToggle;
    uint256 public opsWarp;
    uint256 public opsConfig;
    uint256 public opsCashLend;
    uint256 public opsModuleWithdrawal;
    uint256 public opsCrossModule;

    // Conservation ghosts, measured as exact state deltas
    uint256 public ghost_borrowed; // debt created by driver borrows and credit spends
    uint256 public ghost_repaid; // debt cleared by repays
    uint256 public ghost_dispatcherReceived; // USDC settled to the dispatcher by spends
    uint256 public ghost_totalWarped;

    // Property violations observed inside actions (asserted zero by the invariants)
    uint256 public ghost_parityViolations; // canSpend approved outside a mode window, spend reverted
    uint256 public ghost_debtInflations; // a non-borrowing action increased the debt

    constructor(ICashModule _cashModule, CashLens _cashLens, LendGateway _gw, address _safe, address _etherFiWallet, address _recipient, address _dispatcher, IERC20 _weeth, IERC20 _usdc, CashFlowsInvariantTest _parent, InvariantWithdrawalModule _withdrawalModule, InvariantBalanceCheckedModule _balanceCheckedModule) {
        cashModule = _cashModule;
        cashLens = _cashLens;
        gw = _gw;
        safe = _safe;
        etherFiWallet = _etherFiWallet;
        recipient = _recipient;
        dispatcher = _dispatcher;
        weeth = _weeth;
        usdc = _usdc;
        parent = _parent;
        withdrawalModule = _withdrawalModule;
        balanceCheckedModule = _balanceCheckedModule;
    }

    // ----------------------------------------------------------------- gateway ops (driver)

    /// Deals fresh weETH to the safe and supplies it to Aave as collateral.
    function supplyWeeth(uint256 amt) external {
        amt = bound(amt, 0.1 ether, 20 ether);
        deal(address(weeth), safe, weeth.balanceOf(safe) + amt);
        uint256 debtBefore = gw.debtOf(safe, address(usdc));
        gw.supply(safe, address(weeth), amt);
        gw.setUsingAsCollateral(safe, address(weeth), true);
        _checkNoDebtInflation(debtBefore);
        opsGateway++;
    }

    /// Borrows USDC within the position's available borrowing power, recording the exact debt created.
    function borrowUsdc(uint256 amt) external {
        uint256 powerUsd = gw.getAccountData(safe).availableBorrowsUsd;
        if (powerUsd < 2e6) {
            return;
        }
        uint256 max = powerUsd > 5000e6 ? 5000e6 : powerUsd - 1e6;
        amt = bound(amt, 1e6, max);
        uint256 debtBefore = gw.debtOf(safe, address(usdc));
        gw.borrow(safe, address(usdc), amt, recipient);
        ghost_borrowed += gw.debtOf(safe, address(usdc)) - debtBefore;
        opsGateway++;
    }

    /// Repays up to (and past, for the dust-refund path) the open debt, recording the exact debt cleared.
    function repayUsdc(uint256 amt) external {
        uint256 debt = gw.debtOf(safe, address(usdc));
        if (debt == 0) {
            return;
        }
        amt = bound(amt, 1, debt + 50e6); // may exceed debt -> exercises the dust-refund path
        deal(address(usdc), safe, usdc.balanceOf(safe) + amt);
        gw.repay(safe, address(usdc), amt);
        ghost_repaid += debt - gw.debtOf(safe, address(usdc));
        opsGateway++;
    }

    /// Withdraws part of the supplied weETH to an external recipient (health permitting).
    function withdrawWeeth(uint256 amt) external {
        uint256 supplied = gw.suppliedOf(safe, address(weeth));
        if (supplied == 0) {
            return;
        }
        amt = bound(amt, 1, supplied);
        uint256 debtBefore = gw.debtOf(safe, address(usdc));
        gw.withdraw(safe, address(weeth), amt, recipient);
        _checkNoDebtInflation(debtBefore);
        opsGateway++;
    }

    /// Covers the remaining mutable gateway position operation. Disabling collateral may revert while
    /// debt is open, but successful toggles must not change debt or reservation coverage.
    function toggleWeethCollateral(bool enabled) external {
        uint256 debtBefore = gw.debtOf(safe, address(usdc));
        gw.setUsingAsCollateral(safe, address(weeth), enabled);
        _checkNoDebtInflation(debtBefore);
        opsGateway++;
    }

    // ----------------------------------------------------------------- CashModule lend integration

    /// Exercises the signed CashModule borrow page, including borrow -> Safe -> best-effort supply-back.
    function borrowUsdcThroughCashModule(uint256 amt) external {
        uint256 powerUsd = gw.getAccountData(safe).availableBorrowsUsd;
        if (powerUsd < 2e6) return;

        uint256 max = powerUsd > 2_000e6 ? 2_000e6 : powerUsd - 1e6;
        amt = bound(amt, 1e6, max);
        uint256 debtBefore = gw.debtOf(safe, address(usdc));
        parent.wrapBorrowUsdc(amt);
        ghost_borrowed += gw.debtOf(safe, address(usdc)) - debtBefore;
        opsCashLend++;
    }

    /// Exercises both public CashModule repayment denominations. Fresh inbound USDC keeps this reachable
    /// even when a direct gateway borrow sent its proceeds outside the Safe.
    function repayUsdcThroughCashModule(uint256 bps, bool tokenAmountPath) external {
        uint256 debtBefore = gw.debtOf(safe, address(usdc));
        if (debtBefore == 0) return;

        bps = bound(bps, 1, 11_000);
        uint256 amount = (debtBefore * bps) / 10_000 + 1;
        deal(address(usdc), safe, usdc.balanceOf(safe) + amount);
        vm.prank(etherFiWallet);
        if (tokenAmountPath) {
            cashModule.repayLendTokenAmount(safe, address(usdc), amount);
        } else {
            cashModule.repay(safe, address(usdc), amount);
        }

        ghost_repaid += debtBefore - gw.debtOf(safe, address(usdc));
        opsCashLend++;
    }

    /// Exercises the auto-supply sweep, which must leave a pending withdrawal reservation loose.
    function sweepLooseToLend(uint256 amt, bool pickWeeth) external {
        IERC20 token = pickWeeth ? weeth : usdc;
        uint256 unit = pickWeeth ? 0.01 ether : 1e6;
        uint256 cap = pickWeeth ? 2 ether : 2_000e6;
        amt = bound(amt, unit, cap);
        deal(address(token), safe, token.balanceOf(safe) + amt);

        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        uint256 debtBefore = gw.debtOf(safe, address(usdc));
        vm.prank(etherFiWallet);
        cashModule.supplyToLend(safe, tokens);
        _checkNoDebtInflation(debtBefore);
        opsCashLend++;
    }

    // ----------------------------------------------------------------- card spends

    /// External so the handler can try/catch the spend's revert.
    function externalSpend(bytes32 txId, uint256 amountUsd) external {
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amountUsd;
        vm.prank(etherFiWallet);
        cashModule.spend(safe, txId, BinSponsor.Reap, tokens, amounts, noCashback);
    }

    /// Spends on whichever mode execution will run, sized against that mode's lens quote, with an inline
    /// approved-must-settle spot-check (full parity classification lives in the parity fuzz).
    function spendCard(uint256 bps) external {
        bps = bound(bps, 1, 11_000);
        bool credit = cashModule.getMode(safe) == Mode.Credit;
        uint256 quote;
        if (credit) {
            quote = cashLens.getMaxSpendCredit(safe);
        } else {
            address[] memory prefs = new address[](1);
            prefs[0] = address(usdc);
            quote = cashLens.getMaxSpendDebit(safe, prefs).totalSpendableInUsd;
        }
        uint256 amountUsd = (quote * bps) / 10_000;
        if (amountUsd == 0) {
            amountUsd = 1;
        }

        bytes32 txId = keccak256(abi.encode("cashflow", ++txNonce));
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amountUsd;
        (bool ok,) = cashLens.canSpend(safe, txId, tokens, amounts);
        // Open only while the pending mode has not matured: the start time stays in storage after
        // maturity until a write syncs it, and by then canSpend and spend agree again, so treating
        // any non-zero start time as a window would mute this check for the rest of the campaign
        SafeData memory data = cashModule.getData(safe);
        bool windowOpen = data.incomingModeStartTime != 0 && block.timestamp <= data.incomingModeStartTime && data.incomingMode != data.mode;

        uint256 debtBefore = gw.debtOf(safe, address(usdc));
        uint256 dispatcherBefore = usdc.balanceOf(dispatcher);
        bool spent;
        try this.externalSpend(txId, amountUsd) {
            spent = true;
        } catch { }

        if (ok && !spent && !windowOpen) {
            ghost_parityViolations++;
        }
        if (spent) {
            ghost_dispatcherReceived += usdc.balanceOf(dispatcher) - dispatcherBefore;
            if (credit) {
                ghost_borrowed += gw.debtOf(safe, address(usdc)) - debtBefore;
            } else {
                _checkNoDebtInflation(debtBefore);
            }
            opsSpend++;
        }
    }

    // ----------------------------------------------------------------- balance-checked cross-module flow

    /// Uses the same ModuleCheckBalance base and EtherFiSafe.execTransactionFromModule path as the
    /// integration modules. The successful amount is bounded to the loose balance not reserved by Cash.
    function consumeThroughBalanceCheckedModule(uint256 bps, bool pickWeeth) external {
        bps = bound(bps, 1, 10_000);
        IERC20 token = pickWeeth ? weeth : usdc;
        uint256 loose = token.balanceOf(safe);
        uint256 pending = cashModule.getPendingWithdrawalAmount(safe, address(token));
        uint256 idle = loose > pending ? loose - pending : 0;
        if (idle == 0) return;
        uint256 amount = (idle * bps) / 10_000;
        if (amount == 0) amount = 1;

        uint256 debtBefore = gw.debtOf(safe, address(usdc));
        balanceCheckedModule.consume(safe, address(token), amount, recipient);
        _checkNoDebtInflation(debtBefore);
        opsCrossModule++;
    }

    // ----------------------------------------------------------------- signature-gated flows (via parent)

    /// Places a request against the maximum sourceable balance, reaching fully swept Safes and the
    /// Aave -> Safe sourcing branch rather than limiting exploration to loose balances.
    function requestWithdrawal(uint256 bps, bool pickWeeth) external {
        bps = bound(bps, 1, 10_000);
        address token = pickWeeth ? address(weeth) : address(usdc);
        uint256 sourceable = cashLens.getMaxSourceable(safe, token);
        if (sourceable == 0) return;
        uint256 debtBefore = gw.debtOf(safe, address(usdc));
        uint256 amount = (sourceable * bps) / 10_000;
        if (amount == 0) amount = 1;
        parent.wrapRequestWithdrawal(token, amount);
        _checkNoDebtInflation(debtBefore);
        opsWithdrawalFlow++;
    }

    /// Covers the cross-module branch used by bridge/integration modules.
    function requestWithdrawalByModule(uint256 bps, bool pickWeeth) external {
        bps = bound(bps, 1, 10_000);
        address token = pickWeeth ? address(weeth) : address(usdc);
        uint256 sourceable = cashLens.getMaxSourceable(safe, token);
        if (sourceable == 0) return;
        uint256 amount = (sourceable * bps) / 10_000;
        if (amount == 0) amount = 1;

        uint256 debtBefore = gw.debtOf(safe, address(usdc));
        withdrawalModule.request(safe, token, amount);
        _checkNoDebtInflation(debtBefore);
        opsModuleWithdrawal++;
    }

    function cancelWithdrawalByModule() external {
        WithdrawalRequest memory request = cashModule.getData(safe).pendingWithdrawalRequest;
        if (request.tokens.length == 0 || request.recipient != address(withdrawalModule)) return;
        uint256 debtBefore = gw.debtOf(safe, address(usdc));
        withdrawalModule.cancel(safe);
        _checkNoDebtInflation(debtBefore);
        opsModuleWithdrawal++;
    }

    function processWithdrawalByModule() external {
        WithdrawalRequest memory request = cashModule.getData(safe).pendingWithdrawalRequest;
        if (request.tokens.length == 0 || request.recipient != address(withdrawalModule) || block.timestamp < request.finalizeTime) return;
        uint256 debtBefore = gw.debtOf(safe, address(usdc));
        withdrawalModule.process(safe);
        _checkNoDebtInflation(debtBefore);
        opsModuleWithdrawal++;
    }

    /// Cancels the pending withdrawal request, if any.
    function cancelWithdrawal() external {
        uint256 debtBefore = gw.debtOf(safe, address(usdc));
        if (!parent.wrapCancelWithdrawal()) {
            return;
        }
        _checkNoDebtInflation(debtBefore);
        opsWithdrawalFlow++;
    }

    /// Pays out the pending withdrawal request once its delay has matured.
    function processWithdrawal() external {
        uint256 debtBefore = gw.debtOf(safe, address(usdc));
        if (!parent.wrapProcessWithdrawal()) {
            return;
        }
        _checkNoDebtInflation(debtBefore);
        opsWithdrawalFlow++;
    }

    /// Mutates the withdraw-asset whitelist while requests may be live. Delisting can make processing
    /// revert, but it must never alter the Safe balance or make a funded reservation undercollateralized.
    function configureUsdcWithdrawability(bool enabled) external {
        parent.wrapConfigureWithdrawAsset(address(usdc), enabled);
        opsConfig++;
    }

    /// Requests a switch to the opposite mode, optionally warping past the delay so it takes effect.
    function toggleMode(bool warpPastStart) external {
        uint256 beforeWarp = block.timestamp;
        if (warpPastStart) {
            (,, uint64 modeDelay) = cashModule.getDelays();
            if (ghost_totalWarped + uint256(modeDelay) + 1 > 1 hours) return;
        }
        parent.wrapSetModeOpposite(warpPastStart);
        ghost_totalWarped += block.timestamp - beforeWarp;
        opsModeToggle++;
    }

    /// Requests a lend opt-out (enable=false) or opts back in (enable=true).
    function toggleOptOut(bool enable) external {
        parent.wrapToggleLend(enable);
        opsOptOutToggle++;
    }

    /// Finalizes a matured opt-out request (unwinding the Aave position when debt allows).
    function processOptOut() external {
        uint256 readyAt = cashModule.lendOptOutFinalizeTime(safe);
        if (readyAt == 0 || block.timestamp < readyAt) {
            return;
        }
        cashModule.processLendOptOut(safe);
        opsOptOutToggle++;
    }

    // ----------------------------------------------------------------- time

    /// Advances time so interest accrues, capped cumulatively to stay inside oracle staleness.
    function warpAccrue(uint256 dt) external {
        dt = bound(dt, 1 minutes, 10 minutes);
        if (ghost_totalWarped + dt > 1 hours) {
            return; // stay inside oracle staleness, or every later action reverts and the campaign hollows out
        }
        ghost_totalWarped += dt;
        vm.warp(block.timestamp + dt);
        opsWarp++;
    }

    /// Records a violation if the action increased the debt; only borrows and credit spends may.
    /// @dev Only sound for actions that pass no time, since Aave interest would otherwise inflate the debt
    ///      on its own. The two actions that warp (toggleMode, warpAccrue) deliberately do not call this.
    ///      Callers must also invoke it after their risky call, never before: a violation recorded ahead of
    ///      a revert would be rolled back with the rest of the action and lost.
    function _checkNoDebtInflation(uint256 debtBefore) private {
        if (gw.debtOf(safe, address(usdc)) > debtBefore) {
            ghost_debtInflations++;
        }
    }
}

/// Minimal production-shaped module: the real ModuleCheckBalance guard followed by Safe execution.
contract InvariantBalanceCheckedModule is ModuleBase, ModuleCheckBalance {
    constructor(address dataProvider) ModuleBase(dataProvider) ModuleCheckBalance(dataProvider) { }

    function consume(address safe, address token, uint256 amount, address to) external onlyEtherFiSafe(safe) {
        _checkAmountAvailable(safe, token, amount);
        address[] memory targets = new address[](1);
        targets[0] = token;
        uint256[] memory values = new uint256[](1);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(IERC20.transfer.selector, to, amount);
        IEtherFiSafe(safe).execTransactionFromModule(targets, values, calls);
    }
}

/// Minimal bridge-like callback surface for CashModule module-originated reservations.
contract InvariantWithdrawalModule is IBridgeModule {
    ICashModule internal immutable cashModule;
    uint256 public cancellationCallbacks;

    constructor(ICashModule _cashModule) {
        cashModule = _cashModule;
    }

    function setupModule(bytes calldata) external { }

    function request(address safe, address token, uint256 amount) external {
        cashModule.requestWithdrawalByModule(safe, token, amount);
    }

    function cancel(address safe) external {
        cashModule.cancelWithdrawalByModule(safe);
    }

    function process(address safe) external {
        cashModule.processWithdrawal(safe);
    }

    function cancelBridgeByCashModule(address) external override {
        require(msg.sender == address(cashModule), "only cash module");
        cancellationCallbacks++;
    }
}

/// Stateful real-contract campaign over CashModule, EtherFiSafe, CashLens and the Aave v4 gateway.
/// It covers owner/module withdrawals, card spends, mode changes, auto-supply and lend opt-out.
/// Legacy DebtManager migration/liquidation requires a separate state machine because this setup starts
/// with the Safe already committed to the gateway engine.
contract CashFlowsInvariantTest is CashGatewayTestSetup {
    using MessageHashUtils for bytes32;

    CashFlowsHandler internal handler;
    InvariantWithdrawalModule internal withdrawalModule;
    InvariantBalanceCheckedModule internal balanceCheckedModule;
    uint256 internal dispatcherBaseline;

    /// Deploys the handler, authorizes it as a gateway driver, and targets it for the campaign.
    function setUp() public override {
        super.setUp();

        withdrawalModule = new InvariantWithdrawalModule(ICashModule(address(cashModule)));
        balanceCheckedModule = new InvariantBalanceCheckedModule(address(dataProvider));

        address[] memory modules = new address[](2);
        modules[0] = address(withdrawalModule);
        modules[1] = address(balanceCheckedModule);
        bool[] memory enabled = new bool[](2);
        enabled[0] = true;
        enabled[1] = true;
        vm.prank(owner);
        dataProvider.configureModules(modules, enabled);
        _configureModules(modules, enabled, new bytes[](2));

        address[] memory withdrawalModules = new address[](1);
        withdrawalModules[0] = address(withdrawalModule);
        bool[] memory canRequest = new bool[](1);
        canRequest[0] = true;
        vm.prank(owner);
        cashModule.configureModulesCanRequestWithdraw(withdrawalModules, canRequest);

        handler = new CashFlowsHandler(ICashModule(address(cashModule)), cashLens, gw, address(safe), etherFiWallet, recipient, address(settlementDispatcherReap), weETH, usdc, this, withdrawalModule, balanceCheckedModule);
        vm.prank(owner);
        gw.setDriver(address(handler), true);

        dispatcherBaseline = usdc.balanceOf(address(settlementDispatcherReap));
        targetContract(address(handler));
        targetSelector(FuzzSelector({ addr: address(handler), selectors: _handlerActions() }));
    }

    /// @dev The campaign's action set, listed explicitly rather than left to "every external on the handler":
    ///      `externalSpend` is external only so `spendCard` can try/catch it, and a direct fuzz call to it
    ///      settles a spend (and in credit mode creates debt) without touching the ghosts the conservation
    ///      invariants measure against, which breaks them on the seeds that reach it.
    function _handlerActions() private pure returns (bytes4[] memory actions) {
        actions = new bytes4[](21);
        actions[0] = CashFlowsHandler.supplyWeeth.selector;
        actions[1] = CashFlowsHandler.borrowUsdc.selector;
        actions[2] = CashFlowsHandler.repayUsdc.selector;
        actions[3] = CashFlowsHandler.withdrawWeeth.selector;
        actions[4] = CashFlowsHandler.spendCard.selector;
        actions[5] = CashFlowsHandler.requestWithdrawal.selector;
        actions[6] = CashFlowsHandler.cancelWithdrawal.selector;
        actions[7] = CashFlowsHandler.processWithdrawal.selector;
        actions[8] = CashFlowsHandler.toggleMode.selector;
        actions[9] = CashFlowsHandler.toggleOptOut.selector;
        actions[10] = CashFlowsHandler.processOptOut.selector;
        actions[11] = CashFlowsHandler.warpAccrue.selector;
        actions[12] = CashFlowsHandler.configureUsdcWithdrawability.selector;
        actions[13] = CashFlowsHandler.borrowUsdcThroughCashModule.selector;
        actions[14] = CashFlowsHandler.repayUsdcThroughCashModule.selector;
        actions[15] = CashFlowsHandler.sweepLooseToLend.selector;
        actions[16] = CashFlowsHandler.requestWithdrawalByModule.selector;
        actions[17] = CashFlowsHandler.cancelWithdrawalByModule.selector;
        actions[18] = CashFlowsHandler.processWithdrawalByModule.selector;
        actions[19] = CashFlowsHandler.toggleWeethCollateral.selector;
        actions[20] = CashFlowsHandler.consumeThroughBalanceCheckedModule.selector;
    }

    /// @dev A larger seed so the campaign's bounded borrows are never capped by reserve liquidity.
    function _seedInitialLiquidity() internal override {
        _seedAaveLiquidity(usdcReserveId, address(usdc), 5_000_000e6);
    }

    // ----------------------------------------------------------------- wrappers (owner keys live here)

    /// Signs and places a withdrawal request of `amount` of `token` on the handler's behalf.
    function wrapRequestWithdrawal(address token, uint256 amount) external {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        _requestWithdrawal(tokens, amounts, withdrawRecipient);
    }

    /// Builds the owner quorum and submits the signed production borrow intent.
    function wrapBorrowUsdc(uint256 amountInUsd) external {
        bytes32 digest = keccak256(abi.encodePacked(CashVerificationLib.BORROW_METHOD, block.chainid, address(safe), safe.nonce(), abi.encode(address(usdc), amountInUsd))).toEthSignedMessageHash();
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digest);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digest);
        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);
        cashModule.borrow(address(safe), address(usdc), amountInUsd, signers, signatures);
    }

    /// Signs and cancels the pending withdrawal request; false when none exists.
    function wrapCancelWithdrawal() external returns (bool) {
        WithdrawalRequest memory request = cashModule.getData(address(safe)).pendingWithdrawalRequest;
        if (request.tokens.length == 0) {
            return false;
        }
        _cancelWithdrawal(request.tokens, request.amounts, request.recipient);
        return true;
    }

    /// Processes the pending withdrawal request; false when none exists or the delay has not matured.
    function wrapProcessWithdrawal() external returns (bool) {
        WithdrawalRequest memory request = cashModule.getData(address(safe)).pendingWithdrawalRequest;
        if (request.tokens.length == 0 || block.timestamp < request.finalizeTime) {
            return false;
        }
        cashModule.processWithdrawal(address(safe));
        return true;
    }

    /// Applies the same controller configuration change used in production while the state machine runs.
    function wrapConfigureWithdrawAsset(address token, bool enabled) public {
        address[] memory assets = new address[](1);
        assets[0] = token;
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = enabled;
        vm.prank(owner);
        cashModule.configureWithdrawAssets(assets, shouldWhitelist);
    }

    /// Signs a switch to the opposite of the effective mode, optionally warping past the delay.
    /// @dev Reads getMode, not stored mode: storage lags a matured pending change, and setMode syncs
    ///      it before its ModeAlreadySet check, so toggling off stale storage would silently revert.
    function wrapSetModeOpposite(bool warpPastStart) external {
        Mode effective = cashModule.getMode(address(safe));
        _setMode(effective == Mode.Debit ? Mode.Credit : Mode.Debit);
        if (warpPastStart) {
            vm.warp(cashModule.incomingModeStartTime(address(safe)) + 1);
        }
    }

    /// Signs a lend toggle: enable=false requests an opt-out, enable=true opts back in.
    function wrapToggleLend(bool enable) external {
        uint256 nonce = cashModule.getNonce(address(safe));
        bytes32 digest = keccak256(abi.encodePacked(CashVerificationLib.TOGGLE_LEND_METHOD, block.chainid, address(safe), nonce, abi.encode(enable))).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digest);
        cashModule.toggleLend(address(safe), enable, owner1, abi.encodePacked(r, s, v));
    }

    // ----------------------------------------------------------------- invariants (live state)

    /// @notice Funds never strand on the plumbing: gateway, module, and lens hold nothing, and the
    ///         dispatcher received exactly what the spends settled.
    function invariant_noStrandedFunds() external view {
        assertEq(weETH.balanceOf(address(gw)), 0, "no stranded weETH in gateway");
        assertEq(usdc.balanceOf(address(gw)), 0, "no stranded USDC in gateway");
        assertEq(usdc.balanceOf(address(cashModule)), 0, "no stranded USDC in module");
        assertEq(usdc.balanceOf(address(cashLens)), 0, "no stranded USDC in lens");
        assertEq(usdc.balanceOf(address(settlementDispatcherReap)), dispatcherBaseline + handler.ghost_dispatcherReceived(), "dispatcher holds exactly the settled spends");
    }

    /// @notice A pending withdrawal reservation always stays fundable from the safe's pots: the flows
    ///         that would undercut it (spends, sweeps) must cancel it instead.
    function invariant_reservationStaysFundable() external view {
        WithdrawalRequest memory request = cashModule.getData(address(safe)).pendingWithdrawalRequest;
        for (uint256 i = 0; i < request.tokens.length; i++) {
            address token = request.tokens[i];
            assertLe(request.amounts[i], IERC20(token).balanceOf(address(safe)) + gw.suppliedOf(address(safe), token), "reservation exceeds the safe's pots");
        }
    }

    /// @notice Stronger reservation invariant: request creation pulls the complete amount out of Aave,
    ///         so every live request must remain covered by the Safe's loose balance. Normal spends,
    ///         repayments, sweeps and configuration changes must preserve this or cancel the request.
    function invariant_pendingNeverExceedsLooseBalance() external view {
        WithdrawalRequest memory request = cashModule.getData(address(safe)).pendingWithdrawalRequest;
        for (uint256 i = 0; i < request.tokens.length; i++) {
            assertLe(request.amounts[i], IERC20(request.tokens[i]).balanceOf(address(safe)), "pending withdrawal exceeds loose Safe balance");
        }
    }

    /// @notice Debt only exists from borrows and credit spends: cleared plus outstanding always covers
    ///         created (interest only inflates the outstanding side), and zero borrows means zero debt.
    function invariant_debtOnlyFromBorrows() external view {
        uint256 debt = gw.debtOf(address(safe), address(usdc));
        if (handler.ghost_borrowed() == 0) {
            assertEq(debt, 0, "debt with no borrow or credit spend");
        }
        assertGe(debt + handler.ghost_repaid(), handler.ghost_borrowed(), "debt vanished outside a repay");
    }

    /// @notice No action observed a property violation (parity spot-checks, debt inflation).
    function invariant_noObservedViolations() external view {
        assertEq(handler.ghost_parityViolations(), 0, "an approved spend failed outside a mode window");
        assertEq(handler.ghost_debtInflations(), 0, "a non-borrowing action increased the debt");
    }

    /**
     * @notice Proves every handler action drives real state, so the invariants are not passing vacuously
     *         over a hollow, all-reverting campaign.
     * @dev A plain test rather than afterInvariant: Foundry reverts the handler's state to the setUp
     *      snapshot before afterInvariant, so a ghost counter read there always sees zero.
     */
    function test_handlerDrivesRealOps() public {
        handler.supplyWeeth(5 ether);
        deal(address(usdc), address(safe), 100e6);
        handler.spendCard(5000); // debit
        handler.requestWithdrawal(5000, false);
        handler.consumeThroughBalanceCheckedModule(5000, false);
        handler.cancelWithdrawal();
        handler.requestWithdrawal(5000, false);
        handler.warpAccrue(10 minutes);
        handler.processWithdrawal();
        handler.sweepLooseToLend(50e6, false);
        handler.requestWithdrawalByModule(1000, true);
        handler.cancelWithdrawalByModule();
        handler.requestWithdrawalByModule(1000, true);
        handler.warpAccrue(10 minutes);
        handler.processWithdrawalByModule();
        handler.toggleOptOut(false); // debt-free here: a request with open borrows reverts
        handler.toggleOptOut(true);
        handler.toggleWeethCollateral(false);
        handler.toggleWeethCollateral(true);
        handler.borrowUsdc(100e6);
        handler.repayUsdc(50e6);
        handler.borrowUsdcThroughCashModule(50e6);
        handler.repayUsdcThroughCashModule(5000, true);
        handler.withdrawWeeth(1);
        handler.toggleMode(true); // to credit, matured; storage now lags the effective mode
        handler.toggleMode(true); // to debit, through stale storage (reverted ModeAlreadySet off the stored mode)
        handler.toggleMode(true); // back to credit
        handler.spendCard(5000); // credit
        handler.configureUsdcWithdrawability(false);
        handler.configureUsdcWithdrawability(true);

        assertEq(handler.opsGateway(), 6, "gateway ops executed");
        assertEq(handler.opsSpend(), 2, "debit and credit spends settled");
        assertEq(handler.opsWithdrawalFlow(), 4, "requests, cancel, and process executed");
        assertEq(handler.opsModeToggle(), 3, "mode toggles executed, including one off a matured pending");
        assertEq(handler.opsOptOutToggle(), 2, "opt-out toggles executed");
        assertEq(handler.opsWarp(), 2, "accrual warps executed");
        assertEq(handler.opsCashLend(), 3, "CashModule lend routes executed");
        assertEq(handler.opsModuleWithdrawal(), 4, "module request, cancel, and process executed");
        assertEq(handler.opsConfig(), 2, "withdraw-asset config mutations executed");
        assertEq(handler.opsCrossModule(), 1, "balance-checked module transfer executed");
        assertEq(handler.ghost_parityViolations(), 0, "no parity violations");
        assertEq(handler.ghost_debtInflations(), 0, "no debt inflation");
    }

    /// @notice Models a whitelisted token whose balance can decrease without a Safe transfer. This is not
    ///         a claim about USDC/weETH: it proves the strict invariant depends on token semantics and shows
    ///         that the ordinary owner-cancellation path still deletes the now-unfunded request.
    function test_negativeRebaseCanMakePendingExceedLooseBalance() public {
        NegativeRebaseToken token = new NegativeRebaseToken();
        wrapConfigureWithdrawAsset(address(token), true);

        token.mint(address(safe), 1_000 ether);
        _requestWithdrawal(_singleAddress(address(token)), _singleUint(800 ether), withdrawRecipient);

        token.rebaseDown(address(safe), 300 ether);

        WithdrawalRequest memory request = cashModule.getData(address(safe)).pendingWithdrawalRequest;
        assertEq(request.amounts[0], 800 ether);
        assertEq(token.balanceOf(address(safe)), 700 ether);
        assertGt(request.amounts[0], token.balanceOf(address(safe)), "negative rebase must underfund reservation");
        assertEq(cashLens.getMaxSourceable(address(safe), address(token)), 0, "lens clamps the deficit to zero");

        vm.warp(request.finalizeTime);
        vm.expectRevert();
        cashModule.processWithdrawal(address(safe));

        _cancelWithdrawal(request.tokens, request.amounts, request.recipient);
        assertEq(cashModule.getData(address(safe)).pendingWithdrawalRequest.tokens.length, 0, "owner cancellation recovers request state");
    }

    function _singleAddress(address value) private pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = value;
    }

    function _singleUint(uint256 value) private pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = value;
    }
}

/// @dev Test-only negative-rebase model: an external protocol event can burn an account's units without
///      making the Safe call transfer, exactly the token-semantic case the reservation cannot intercept.
contract NegativeRebaseToken is ERC20 {
    constructor() ERC20("Negative Rebase Token", "NRT") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function rebaseDown(address account, uint256 amount) external {
        _burn(account, amount);
    }
}
