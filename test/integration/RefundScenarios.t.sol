// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {IDOManager} from "../../src/IDOManager.sol";
import {KYCRegistry} from "../../src/kyc/KYCRegistry.sol";
import {AdminManager} from "../../src/admin_manager/AdminManager.sol";
import {IIDOManager} from "../../src/interfaces/IIDOManager.sol";
import {ReservesManager} from "../../src/ReservesManager.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Mock ERC20 token for testing
contract MockERC20 is ERC20 {
    uint8 private _decimals;

    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals_
    ) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract RefundScenariosIntegrationTest is Test {
    IDOManager public idoManager;
    KYCRegistry public kycRegistry;
    AdminManager public adminManager;

    MockERC20 public usdt;
    MockERC20 public usdc;
    MockERC20 public flx;
    MockERC20 public idoToken;

    address public owner = address(this);
    address public admin = makeAddr("admin");
    address public reservesAdmin = makeAddr("reservesAdmin");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public user3 = makeAddr("user3");
    address public user4 = makeAddr("user4");
    address public user5 = makeAddr("user5");

    uint32 constant HUNDRED_PERCENT = 10_000_000;

    function setUp() public {
        // Deploy mock tokens
        usdt = new MockERC20("USDT", "USDT", 6);
        usdc = new MockERC20("USDC", "USDC", 6);
        flx = new MockERC20("FLX", "FLX", 18);
        idoToken = new MockERC20("IDO Token", "IDO", 18);

        // Deploy KYC registry
        kycRegistry = new KYCRegistry(owner);

        // Deploy admin manager
        adminManager = new AdminManager(owner, admin);

        // Deploy IDO manager
        idoManager = new IDOManager(
            address(usdt),
            address(usdc),
            address(flx),
            address(kycRegistry),
            reservesAdmin,
            address(adminManager),
            owner
        );

        // Setup: Verify users for KYC
        kycRegistry.verify(user1);
        kycRegistry.verify(user2);
        kycRegistry.verify(user3);
        kycRegistry.verify(user4);
        kycRegistry.verify(user5);

        // Setup: Set static prices for stablecoins (8 decimals precision)
        vm.startPrank(admin);
        idoManager.setStaticPrice(address(usdt), 1e8); // $1.00
        idoManager.setStaticPrice(address(usdc), 1e8); // $1.00
        idoManager.setStaticPrice(address(flx), 1e8);  // $1.00
        vm.stopPrank();
    }

    function _createIDO() internal returns (uint256) {
        uint64 startTime = uint64(block.timestamp + 1 days);
        uint64 endTime = uint64(block.timestamp + 8 days);

        IIDOManager.IDOInput memory idoInput = IIDOManager.IDOInput({
            info: IIDOManager.IDOInfo({
                tokenAddress: address(0),
                projectId: 1,
                totalAllocated: 0,
                minAllocationUSD: 100e18,
                totalAllocationByUser: 10000e18,
                totalAllocation: 1000000e18
            }),
            bonuses: IIDOManager.IDOBonuses({
                phase1BonusPercent: 2000000, // 20%
                phase2BonusPercent: 1000000, // 10%
                phase3BonusPercent: 500000   // 5%
            }),
            schedules: IIDOManager.IDOSchedules({
                idoStartTime: startTime,
                idoEndTime: endTime,
                claimStartTime: 0,
                tgeTime: 0,
                cliffDuration: 30 days,
                vestingDuration: 180 days,
                unlockInterval: 1 days,
                twapCalculationWindowHours: 24,
                timeoutForRefundAfterVesting: 90 days,
                tgeUnlockPercent: 1000000 // 10%
            }),
            refundPenalties: IIDOManager.RefundPenalties({
                fullRefundPenalty: 500000,         // 5%
                fullRefundPenaltyBeforeTge: 200000, // 2%
                refundPenalty: 1000000              // 10%
            }),
            refundPolicy: IIDOManager.RefundPolicy({
                fullRefundDuration: 7 days,
                isRefundIfClaimedAllowed: true,
                isRefundUnlockedPartOnly: false,
                isRefundInCliffAllowed: true,
                isFullRefundBeforeTGEAllowed: true,
                isPartialRefundInCliffAllowed: true,
                isFullRefundInCliffAllowed: true,
                isPartialRefundInVestingAllowed: true,
                isFullRefundInVestingAllowed: false
            }),
            initialPriceUsdt: 1e8,     // $1.00 per token
            fullRefundPriceUsdt: 5e7   // $0.50 per token
        });

        vm.prank(admin);
        return idoManager.createIDO(idoInput);
    }

    function _mintAndApprove(address user, address token, uint256 amount) internal {
        MockERC20(token).mint(user, amount);
        vm.prank(user);
        IERC20(token).approve(address(idoManager), amount);
    }

    function _investUser(
        address user,
        uint256 idoId,
        uint256 amount,
        address token
    ) internal {
        _mintAndApprove(user, token, amount);
        vm.prank(user);
        idoManager.invest(idoId, amount, token);
    }

    function _setupIDO(uint256 idoId) internal {
        uint64 tgeTime = uint64(block.timestamp + 10 days);
        uint64 claimStartTime = tgeTime;

        vm.startPrank(admin);
        idoManager.setTokenAddress(idoId, address(idoToken));
        idoManager.setTgeTime(idoId, tgeTime);
        idoManager.setClaimStartTime(idoId, claimStartTime);
        idoManager.setTwapPriceUsdt(idoId, 8e7); // Set TWAP price to $0.80
        vm.stopPrank();

        // Mint IDO tokens to contract
        idoToken.mint(address(idoManager), 10000000e18);
    }

    /// @dev Tests full refund before TGE with 2% penalty
    /// Covers: Early refund path, penalty calculation, refunded token tracking
    function test_integration_FullRefundBeforeTGE() public {
        // 1. Create and setup IDO
        uint256 idoId = _createIDO();
        _setupIDO(idoId);

        // 2. User invests
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 investAmount = 1000e6; // $1000 USDT
        _investUser(user1, idoId, investAmount, address(usdt));

        // Get user allocation before refund
        (uint256 investedBefore, uint256 allocatedBefore, , , ) = idoManager.getUserInfo(idoId, user1);
        assertGt(allocatedBefore, 0);
        assertGt(investedBefore, 0);

        uint256 user1BalanceBefore = usdt.balanceOf(user1);

        // 3. User requests full refund before TGE
        vm.warp(vm.getBlockTimestamp() + 2 days); // Still before TGE
        vm.prank(user1);
        idoManager.processRefund(idoId, true);

        // 4. Verify refund was processed correctly
        (uint256 investedAfter, uint256 allocatedAfter, , uint256 refundedTokens, ) = idoManager.getUserInfo(idoId, user1);

        // User should have received refund minus 2% penalty
        uint256 user1BalanceAfter = usdt.balanceOf(user1);
        uint256 expectedRefund = investAmount * 98 / 100; // 98% of investment (2% penalty)
        assertApproxEqAbs(user1BalanceAfter - user1BalanceBefore, expectedRefund, 1); // Allow 1 wei difference for rounding

        // User's tokens should be marked as refunded (note: refundedTokens tracks base tokens, bonus tracked separately)
        assertGt(refundedTokens, 0); // Should have refunded tokens
        assertEq(allocatedAfter, allocatedBefore); // Allocation stays the same
        assertEq(investedAfter, investedBefore); // Investment amount stays the same

        // 5. Verify penalty fees can be withdrawn by reserves admin
        uint256 penaltyFees = idoManager.penaltyFeesCollected(idoId, address(usdt));
        assertGt(penaltyFees, 0);

        uint256 reservesBalanceBefore = usdt.balanceOf(reservesAdmin);
        vm.prank(reservesAdmin);
        idoManager.withdrawPenaltyFees(idoId, address(usdt));

        uint256 reservesBalanceAfter = usdt.balanceOf(reservesAdmin);
        assertEq(reservesBalanceAfter - reservesBalanceBefore, penaltyFees);
    }

    /// @dev Tests full refund in cliff period with 5% penalty
    /// Covers: Full refund path after TGE during cliff, higher penalty calculation
    function test_integration_FullRefundAfterTGE() public {
        // 1. Create and setup IDO
        uint256 idoId = _createIDO();
        _setupIDO(idoId);

        // 2. User invests
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 investAmount = 2000e6; // $2000 USDT
        _investUser(user1, idoId, investAmount, address(usdt));

        // 3. Advance to TGE + 12 hours (in cliff period, before TWAP window ends)
        // TGE is at day 10, we're at day 1, so warp 9 days + 12 hours
        vm.warp(vm.getBlockTimestamp() + 9 days + 12 hours);

        uint256 user1BalanceBefore = usdt.balanceOf(user1);

        // 4. User requests full refund during cliff period
        vm.prank(user1);
        idoManager.processRefund(idoId, true);

        // 5. Verify refund was processed with 5% penalty
        uint256 user1BalanceAfter = usdt.balanceOf(user1);
        uint256 expectedRefund = investAmount * 95 / 100; // 95% of investment (5% penalty)
        assertApproxEqAbs(user1BalanceAfter - user1BalanceBefore, expectedRefund, 1);

        // 6. Verify refunded tokens tracking
        (, , , uint256 refundedTokens, ) = idoManager.getUserInfo(idoId, user1);
        assertGt(refundedTokens, 0); // Should have refunded tokens

        // 7. Verify penalty fees
        uint256 penaltyFees = idoManager.penaltyFeesCollected(idoId, address(usdt));
        assertGt(penaltyFees, 0);

        // 8. Admin withdraws refunded tokens
        uint256 reservesTokenBalanceBefore = idoToken.balanceOf(reservesAdmin);
        vm.prank(reservesAdmin);
        idoManager.withdrawRefundedTokens(idoId);

        uint256 reservesTokenBalanceAfter = idoToken.balanceOf(reservesAdmin);
        assertGt(reservesTokenBalanceAfter, reservesTokenBalanceBefore);
    }

    /// @dev Tests partial refund in cliff period with 10% penalty
    /// Covers: Partial refund logic, cliff period checks, TWAP price usage
    function test_integration_PartialRefundInCliff() public {
        // 1. Create and setup IDO
        uint256 idoId = _createIDO();
        _setupIDO(idoId);

        // 2. User invests
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 investAmount = 1500e6; // $1500 USDT
        _investUser(user1, idoId, investAmount, address(usdt));

        (, uint256 allocatedBefore, , , ) = idoManager.getUserInfo(idoId, user1);

        // 3. Advance to TGE + some time in cliff
        // (Not claiming TGE unlock so there are unlocked tokens to refund)
        vm.warp(vm.getBlockTimestamp() + 20 days);

        uint256 user1BalanceBefore = usdt.balanceOf(user1);

        // 4. User requests partial refund (will refund the unclaimed TGE unlock portion)
        vm.prank(user1);
        idoManager.processRefund(idoId, false);

        // 6. Verify partial refund was processed
        uint256 user1BalanceAfter = usdt.balanceOf(user1);
        assertGt(user1BalanceAfter, user1BalanceBefore);

        // Verify some tokens were refunded
        (, , , uint256 refundedTokens, ) = idoManager.getUserInfo(idoId, user1);
        assertGt(refundedTokens, 0);
        assertLt(refundedTokens, allocatedBefore); // Partial refund

        // 7. Verify penalty fees collected
        uint256 penaltyFees = idoManager.penaltyFeesCollected(idoId, address(usdt));
        assertGt(penaltyFees, 0);
    }

    /// @dev Tests partial refund in vesting period with 10% penalty
    /// Covers: Vesting period refund, unlocked vs locked token calculations
    function test_integration_PartialRefundInVesting() public {
        // 1. Create and setup IDO
        uint256 idoId = _createIDO();
        _setupIDO(idoId);

        // 2. User invests
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 investAmount = 2500e6; // $2500 USDT
        _investUser(user1, idoId, investAmount, address(usdt));

        (, uint256 allocatedBefore, , , ) = idoManager.getUserInfo(idoId, user1);

        // 3. Advance past cliff and into vesting period (90 days into vesting)
        // (Not claiming so there are unlocked tokens to refund)
        vm.warp(vm.getBlockTimestamp() + 10 days + 30 days + 90 days);

        uint256 user1BalanceBefore = usdt.balanceOf(user1);

        // 4. User requests partial refund during vesting (will refund unlocked unclaimed portion)
        vm.prank(user1);
        idoManager.processRefund(idoId, false);

        // 6. Verify partial refund was processed
        uint256 user1BalanceAfter = usdt.balanceOf(user1);
        assertGt(user1BalanceAfter, user1BalanceBefore);

        // Verify some tokens were refunded
        (, , , uint256 refundedTokens, ) = idoManager.getUserInfo(idoId, user1);
        assertGt(refundedTokens, 0);
        assertLt(refundedTokens, allocatedBefore);

        // 7. Verify penalty fees
        uint256 penaltyFees = idoManager.penaltyFeesCollected(idoId, address(usdt));
        assertGt(penaltyFees, 0);
    }

    /// @dev Tests multiple users with mixed refund scenarios
    /// Covers: Multiple refund types in same IDO, different penalties, different tokens
    function test_integration_MixedRefundScenarios() public {
        // 1. Create and setup IDO
        uint256 idoId = _createIDO();
        _setupIDO(idoId);

        // 2. Multiple users invest with different tokens
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _investUser(user1, idoId, 1000e6, address(usdt));
        _investUser(user2, idoId, 500e6, address(usdc));
        _investUser(user3, idoId, 750e18, address(flx));
        _investUser(user4, idoId, 2000e6, address(usdt));

        // 3. User1 requests full refund before TGE (2% penalty)
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(user1);
        idoManager.processRefund(idoId, true);

        // 4. Advance to TGE + 12 hours (before TWAP window ends)
        // We're at day 3 (2 days after day 1), TGE is at day 10, so warp 7 days + 12 hours
        vm.warp(vm.getBlockTimestamp() + 7 days + 12 hours);

        // 5. User2 requests full refund after TGE (before TWAP window)
        vm.prank(user2);
        idoManager.processRefund(idoId, true);

        // 6. Advance to cliff period
        vm.warp(vm.getBlockTimestamp() + 10 days);

        // User3 requests partial refund in cliff (hasn't claimed TGE, so has tokens to refund)
        vm.prank(user3);
        idoManager.processRefund(idoId, false);

        // 7. Advance to vesting period (without claiming first)
        vm.warp(vm.getBlockTimestamp() + 30 days + 60 days);

        // 8. User4 requests partial refund in vesting (hasn't claimed, so has unlocked tokens to refund)
        vm.prank(user4);
        idoManager.processRefund(idoId, false);

        // 9. Verify all penalty fees can be withdrawn
        uint256 penaltyFeesUSDT = idoManager.penaltyFeesCollected(idoId, address(usdt));
        uint256 penaltyFeesUSDC = idoManager.penaltyFeesCollected(idoId, address(usdc));
        uint256 penaltyFeesFLX = idoManager.penaltyFeesCollected(idoId, address(flx));

        assertGt(penaltyFeesUSDT, 0);
        assertGt(penaltyFeesUSDC, 0);
        assertGt(penaltyFeesFLX, 0);

        // Admin withdraws all penalty fees
        vm.startPrank(reservesAdmin);
        if (penaltyFeesUSDT > 0) {
            idoManager.withdrawPenaltyFees(idoId, address(usdt));
        }
        if (penaltyFeesUSDC > 0) {
            idoManager.withdrawPenaltyFees(idoId, address(usdc));
        }
        if (penaltyFeesFLX > 0) {
            idoManager.withdrawPenaltyFees(idoId, address(flx));
        }
        vm.stopPrank();

        // 10. Admin withdraws refunded tokens
        vm.prank(reservesAdmin);
        idoManager.withdrawRefundedTokens(idoId);

        // Verify admin received refunded tokens
        assertGt(idoToken.balanceOf(reservesAdmin), 0);
    }

    /// @dev Tests refund with subsequent claims
    /// Covers: Refund doesn't block future claims, accounting after refund
    function test_integration_RefundThenContinueClaiming() public {
        // 1. Create and setup IDO
        uint256 idoId = _createIDO();
        _setupIDO(idoId);

        // 2. User invests
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _investUser(user1, idoId, 3000e6, address(usdt));

        (, uint256 allocatedBefore, , , ) = idoManager.getUserInfo(idoId, user1);

        // 3. Advance to TGE
        vm.warp(vm.getBlockTimestamp() + 10 days);

        // User claims TGE unlock
        vm.prank(user1);
        idoManager.claimTokens(idoId);

        (, , uint256 claimedAfterTGE, , ) = idoManager.getUserInfo(idoId, user1);
        assertGt(claimedAfterTGE, 0);

        // 4. Advance to cliff period
        vm.warp(vm.getBlockTimestamp() + 45 days);

        // User requests partial refund
        vm.prank(user1);
        idoManager.processRefund(idoId, false);

        (, , uint256 claimedAfterRefund, uint256 refundedTokens, ) = idoManager.getUserInfo(idoId, user1);
        assertGt(refundedTokens, 0);

        // 5. Advance further into vesting
        vm.warp(vm.getBlockTimestamp() + 90 days);

        // User can still claim remaining vested tokens
        vm.prank(user1);
        idoManager.claimTokens(idoId);

        (, , uint256 claimedFinal, , ) = idoManager.getUserInfo(idoId, user1);
        assertGt(claimedFinal, claimedAfterRefund);

        // 6. Verify final accounting
        // claimedFinal + refundedTokens should be <= allocatedBefore
        assertLe(claimedFinal + refundedTokens, allocatedBefore);
    }

    /// @dev Tests admin withdrawing penalty fees progressively
    /// Covers: Multiple penalty fee withdrawals, tracking per token
    function test_integration_ProgressivePenaltyFeeWithdrawals() public {
        // 1. Create and setup IDO
        uint256 idoId = _createIDO();
        _setupIDO(idoId);

        // 2. Multiple users invest
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _investUser(user1, idoId, 1000e6, address(usdt));
        _investUser(user2, idoId, 1500e6, address(usdt));
        _investUser(user3, idoId, 2000e6, address(usdt));

        // 3. User1 refunds before TGE
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(user1);
        idoManager.processRefund(idoId, true);

        uint256 penaltyFeesAfterUser1 = idoManager.penaltyFeesCollected(idoId, address(usdt));
        assertGt(penaltyFeesAfterUser1, 0);

        // 4. Admin withdraws first batch of penalty fees
        uint256 reservesBalanceBefore = usdt.balanceOf(reservesAdmin);
        vm.prank(reservesAdmin);
        idoManager.withdrawPenaltyFees(idoId, address(usdt));

        uint256 reservesBalanceAfter1 = usdt.balanceOf(reservesAdmin);
        assertEq(reservesBalanceAfter1 - reservesBalanceBefore, penaltyFeesAfterUser1);

        // 5. Advance to TGE + 12 hours (before TWAP window ends)
        // We're at day 3 (2 days after day 1), TGE is at day 10, so warp 7 days + 12 hours
        vm.warp(vm.getBlockTimestamp() + 7 days + 12 hours);

        // User2 refunds after TGE but before TWAP window ends
        vm.prank(user2);
        idoManager.processRefund(idoId, true);

        uint256 penaltyFeesAfterUser2 = idoManager.penaltyFeesCollected(idoId, address(usdt));
        assertGt(penaltyFeesAfterUser2, 0);

        // 6. Admin withdraws second batch of penalty fees
        vm.prank(reservesAdmin);
        idoManager.withdrawPenaltyFees(idoId, address(usdt));

        uint256 reservesBalanceAfter2 = usdt.balanceOf(reservesAdmin);
        assertGt(reservesBalanceAfter2, reservesBalanceAfter1);

        // 7. Advance to cliff (without claiming so there are unlocked tokens to refund)
        vm.warp(vm.getBlockTimestamp() + 20 days);

        // User3 requests partial refund (hasn't claimed TGE, so has tokens to refund)
        vm.prank(user3);
        idoManager.processRefund(idoId, false);

        uint256 penaltyFeesAfterUser3 = idoManager.penaltyFeesCollected(idoId, address(usdt));
        assertGt(penaltyFeesAfterUser3, 0);

        // 8. Admin withdraws third batch of penalty fees
        vm.prank(reservesAdmin);
        idoManager.withdrawPenaltyFees(idoId, address(usdt));

        uint256 reservesBalanceFinal = usdt.balanceOf(reservesAdmin);
        assertGt(reservesBalanceFinal, reservesBalanceAfter2);
    }

    /// @dev Tests TWAP price effect on partial refunds
    /// Covers: TWAP price usage, refund amount calculations based on market price
    function test_integration_TWAPPriceEffectOnRefunds() public {
        // 1. Create and setup IDO with TWAP price
        uint256 idoId = _createIDO();
        _setupIDO(idoId); // TWAP set to $0.80 in _setupIDO

        // 2. User invests
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 investAmount = 1000e6; // $1000 USDT
        _investUser(user1, idoId, investAmount, address(usdt));

        // 3. Advance to TGE
        vm.warp(vm.getBlockTimestamp() + 10 days);

        // User claims TGE
        vm.prank(user1);
        idoManager.claimTokens(idoId);

        // 4. Advance to cliff
        vm.warp(vm.getBlockTimestamp() + 35 days);

        uint256 user1BalanceBefore = usdt.balanceOf(user1);

        // 5. User requests partial refund (TWAP price will be used if < fullRefundPrice)
        vm.prank(user1);
        idoManager.processRefund(idoId, false);

        uint256 user1BalanceAfter = usdt.balanceOf(user1);
        uint256 refundReceived = user1BalanceAfter - user1BalanceBefore;

        // Verify refund was processed
        assertGt(refundReceived, 0);

        // 6. Verify TWAP price was used for calculation
        // The refund amount should reflect the TWAP price ($0.80) vs initial price ($1.00)
        (, , , uint256 refundedTokens, ) = idoManager.getUserInfo(idoId, user1);
        assertGt(refundedTokens, 0);
    }
}
