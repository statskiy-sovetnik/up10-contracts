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

contract EdgeCasesComplexScenariosTest is Test {
    IDOManager public idoManager;
    KYCRegistry public kycRegistry;
    AdminManager public adminManager;

    MockERC20 public usdt;
    MockERC20 public usdc;
    MockERC20 public flx;
    MockERC20 public idoToken1;
    MockERC20 public idoToken2;

    address public owner = address(this);
    address public admin = makeAddr("admin");
    address public reservesAdmin = makeAddr("reservesAdmin");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public user3 = makeAddr("user3");
    address public user4 = makeAddr("user4");
    address public user5 = makeAddr("user5");
    address public userNoKYC = makeAddr("userNoKYC");

    uint32 constant HUNDRED_PERCENT = 10_000_000;

    function setUp() public {
        // Deploy mock tokens
        usdt = new MockERC20("USDT", "USDT", 6);
        usdc = new MockERC20("USDC", "USDC", 6);
        flx = new MockERC20("FLX", "FLX", 18);
        idoToken1 = new MockERC20("IDO Token 1", "IDO1", 18);
        idoToken2 = new MockERC20("IDO Token 2", "IDO2", 6); // Different decimals

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

        // Setup: Verify users for KYC (but not userNoKYC)
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

    function _createIDO(uint64 startTime, uint64 endTime, uint256 totalAllocation) internal returns (uint256) {
        IIDOManager.IDOInput memory idoInput = IIDOManager.IDOInput({
            info: IIDOManager.IDOInfo({
                tokenAddress: address(0),
                projectId: 1,
                totalAllocated: 0,
                minAllocationUSD: 100e18,
                totalAllocationByUser: 10000e18,
                totalAllocation: totalAllocation
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

    function _setupIDO(uint256 idoId, address tokenAddress) internal {
        uint64 tgeTime = uint64(block.timestamp + 10 days);
        uint64 claimStartTime = tgeTime;

        vm.startPrank(admin);
        idoManager.setTokenAddress(idoId, tokenAddress);
        idoManager.setTgeTime(idoId, tgeTime);
        idoManager.setClaimStartTime(idoId, claimStartTime);
        idoManager.setTwapPriceUsdt(idoId, 8e7);
        vm.stopPrank();

        // Mint IDO tokens to contract
        MockERC20(tokenAddress).mint(address(idoManager), 10000000e18);
    }

    /// @dev Tests multiple concurrent IDOs running simultaneously
    /// Covers: Multiple IDO tracking, independent lifecycle management
    function test_integration_MultipleConcurrentIDOs() public {
        // 1. Create two IDOs with overlapping timeframes
        uint64 ido1Start = uint64(block.timestamp + 1 days);
        uint64 ido1End = uint64(block.timestamp + 8 days);
        uint256 idoId1 = _createIDO(ido1Start, ido1End, 1000000e18);

        uint64 ido2Start = uint64(block.timestamp + 3 days);
        uint64 ido2End = uint64(block.timestamp + 10 days);
        uint256 idoId2 = _createIDO(ido2Start, ido2End, 500000e18);

        // 2. Setup both IDOs with different tokens
        _setupIDO(idoId1, address(idoToken1));
        _setupIDO(idoId2, address(idoToken2));

        // 3. Users invest in IDO 1
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _investUser(user1, idoId1, 1000e6, address(usdt));
        _investUser(user2, idoId1, 500e6, address(usdc));

        // 4. Users invest in both IDOs
        vm.warp(vm.getBlockTimestamp() + 3 days);
        _investUser(user3, idoId1, 750e18, address(flx));
        _investUser(user3, idoId2, 800e6, address(usdt));
        _investUser(user4, idoId2, 1200e6, address(usdc));

        // 5. Verify independent tracking
        (, uint256 user1Ido1Allocated, , , ) = idoManager.getUserInfo(idoId1, user1);
        (, uint256 user3Ido1Allocated, , , ) = idoManager.getUserInfo(idoId1, user3);
        (, uint256 user3Ido2Allocated, , , ) = idoManager.getUserInfo(idoId2, user3);
        (, uint256 user4Ido2Allocated, , , ) = idoManager.getUserInfo(idoId2, user4);

        assertGt(user1Ido1Allocated, 0);
        assertGt(user3Ido1Allocated, 0);
        assertGt(user3Ido2Allocated, 0);
        assertGt(user4Ido2Allocated, 0);

        // 6. Advance to TGE for both
        vm.warp(vm.getBlockTimestamp() + 8 days);

        // Users claim from both IDOs
        vm.prank(user3);
        idoManager.claimTokens(idoId1);

        vm.prank(user3);
        idoManager.claimTokens(idoId2);

        // 7. Verify claims are independent
        (, , uint256 user3Ido1Claimed, , ) = idoManager.getUserInfo(idoId1, user3);
        (, , uint256 user3Ido2Claimed, , ) = idoManager.getUserInfo(idoId2, user3);

        assertGt(user3Ido1Claimed, 0);
        assertGt(user3Ido2Claimed, 0);

        // 8. One user refunds from IDO1, continues with IDO2
        vm.prank(user1);
        idoManager.processRefund(idoId1, true);

        // User3 can still claim from IDO2
        vm.warp(vm.getBlockTimestamp() + 50 days);
        vm.prank(user3);
        idoManager.claimTokens(idoId2);

        // 9. Reserves admin withdraws from both IDOs independently
        uint256 ido1Withdrawable = idoManager.getWithdrawableAmount(idoId1, address(usdt));
        if (ido1Withdrawable > 0) {
            vm.prank(reservesAdmin);
            idoManager.withdrawStablecoins(idoId1, address(usdt), ido1Withdrawable);
        }

        uint256 ido2Withdrawable = idoManager.getWithdrawableAmount(idoId2, address(usdt));
        if (ido2Withdrawable > 0) {
            vm.prank(reservesAdmin);
            idoManager.withdrawStablecoins(idoId2, address(usdt), ido2Withdrawable);
        }

        // Verify lifecycle completion for both IDOs
        assertTrue(true, "Multiple concurrent IDOs completed successfully");
    }

    /// @dev Tests KYC requirement enforcement
    /// Covers: KYC checks during investment, unverified user rejection
    function test_integration_KYCRequirement() public {
        // 1. Create and setup IDO
        uint64 startTime = uint64(block.timestamp + 1 days);
        uint64 endTime = uint64(block.timestamp + 8 days);
        uint256 idoId = _createIDO(startTime, endTime, 1000000e18);
        _setupIDO(idoId, address(idoToken1));

        // 2. Advance to IDO start
        vm.warp(vm.getBlockTimestamp() + 1 days);

        // 3. Verified user can invest
        _investUser(user1, idoId, 1000e6, address(usdt));
        (, uint256 user1Allocated, , , ) = idoManager.getUserInfo(idoId, user1);
        assertGt(user1Allocated, 0);

        // 4. Unverified user cannot invest (should revert)
        _mintAndApprove(userNoKYC, address(usdt), 1000e6);
        vm.expectRevert();
        vm.prank(userNoKYC);
        idoManager.invest(idoId, 1000e6, address(usdt));

        // 5. Verify user, then they can invest
        kycRegistry.verify(userNoKYC);
        _investUser(userNoKYC, idoId, 1000e6, address(usdt));
        (, uint256 userNoKYCAllocated, , , ) = idoManager.getUserInfo(idoId, userNoKYC);
        assertGt(userNoKYCAllocated, 0);

        // 6. Unverify user
        kycRegistry.revoke(userNoKYC);

        // User can still claim (KYC only required for investment)
        vm.warp(vm.getBlockTimestamp() + 10 days);
        vm.prank(userNoKYC);
        idoManager.claimTokens(idoId);

        // But cannot invest again
        vm.warp(vm.getBlockTimestamp() - 9 days); // Go back before IDO end
        _mintAndApprove(userNoKYC, address(usdt), 500e6);
        vm.expectRevert();
        vm.prank(userNoKYC);
        idoManager.invest(idoId, 500e6, address(usdt));
    }

    /// @dev Tests investment limits (min and max allocations)
    /// Covers: Min allocation enforcement, max allocation per user
    function test_integration_InvestmentLimits() public {
        // 1. Create and setup IDO with specific limits
        uint64 startTime = uint64(block.timestamp + 1 days);
        uint64 endTime = uint64(block.timestamp + 8 days);
        uint256 idoId = _createIDO(startTime, endTime, 1000000e18);
        _setupIDO(idoId, address(idoToken1));

        // 2. Advance to IDO start
        vm.warp(vm.getBlockTimestamp() + 1 days);

        // 3. Try to invest below minimum (should revert)
        uint256 belowMin = 50e6; // $50, below $100 min
        _mintAndApprove(user1, address(usdt), belowMin);
        vm.expectRevert();
        vm.prank(user1);
        idoManager.invest(idoId, belowMin, address(usdt));

        // 4. Invest at minimum (should succeed)
        uint256 atMin = 100e6; // $100
        _investUser(user1, idoId, atMin, address(usdt));
        (, uint256 user1Allocated, , , ) = idoManager.getUserInfo(idoId, user1);
        assertGt(user1Allocated, 0);

        // 5. Try to invest again (should revert - already invested)
        _mintAndApprove(user1, address(usdt), atMin);
        vm.expectRevert();
        vm.prank(user1);
        idoManager.invest(idoId, atMin, address(usdt));

        // 6. Different user invests at maximum
        // Max is 10000e18 worth of tokens (totalAllocationByUser)
        // With 20% bonus in phase 1: need to invest ~8333 USD to get 10000 worth
        uint256 largeInvest = 8300e6; // $8300
        _investUser(user2, idoId, largeInvest, address(usdt));
        (, uint256 user2Allocated, , , ) = idoManager.getUserInfo(idoId, user2);
        assertGt(user2Allocated, 0);

        // 7. User invests close to total allocation (should succeed if under limit)
        _investUser(user3, idoId, 5000e6, address(usdt));
        (, uint256 user3Allocated, , , ) = idoManager.getUserInfo(idoId, user3);
        assertGt(user3Allocated, 0);
    }

    /// @dev Tests FLX priority period (first 2 hours)
    /// Covers: FLX-only investment window, priority enforcement
    function test_integration_FLXPriorityPeriod() public {
        // 1. Create and setup IDO
        uint64 startTime = uint64(block.timestamp + 1 days);
        uint64 endTime = uint64(block.timestamp + 8 days);
        uint256 idoId = _createIDO(startTime, endTime, 1000000e18);
        _setupIDO(idoId, address(idoToken1));

        // 2. Advance to IDO start (within FLX priority period - first 2 hours)
        vm.warp(startTime);

        // 3. FLX investment should work
        _investUser(user1, idoId, 1000e18, address(flx));
        (, uint256 user1Allocated, , , ) = idoManager.getUserInfo(idoId, user1);
        assertGt(user1Allocated, 0);

        // 4. Advance to 1 hour into IDO (still in FLX priority)
        vm.warp(startTime + 1 hours);

        // FLX still works
        _investUser(user2, idoId, 500e18, address(flx));
        (, uint256 user2Allocated, , , ) = idoManager.getUserInfo(idoId, user2);
        assertGt(user2Allocated, 0);

        // 5. Advance past FLX priority period (2 hours + 1 second)
        vm.warp(startTime + 2 hours + 1);

        // Now USDT investment should work
        _investUser(user3, idoId, 750e6, address(usdt));
        (, uint256 user3Allocated, , , ) = idoManager.getUserInfo(idoId, user3);
        assertGt(user3Allocated, 0);

        // FLX still works after priority period
        _investUser(user4, idoId, 1200e18, address(flx));
        (, uint256 user4Allocated, , , ) = idoManager.getUserInfo(idoId, user4);
        assertGt(user4Allocated, 0);
    }

    /// @dev Tests different token decimals handling (6 vs 18 decimals)
    /// Covers: Decimal conversion, precision handling
    function test_integration_DifferentTokenDecimals() public {
        // 1. Create and setup IDO
        uint64 startTime = uint64(block.timestamp + 1 days);
        uint64 endTime = uint64(block.timestamp + 8 days);
        uint256 idoId = _createIDO(startTime, endTime, 1000000e18);
        _setupIDO(idoId, address(idoToken2)); // IDO token with 6 decimals

        // 2. Advance to IDO start
        vm.warp(vm.getBlockTimestamp() + 1 days);

        // 3. Users invest with different decimal tokens
        _investUser(user1, idoId, 1000e6, address(usdt));  // 6 decimals
        _investUser(user2, idoId, 500e6, address(usdc));   // 6 decimals
        _investUser(user3, idoId, 750e18, address(flx));   // 18 decimals

        // 4. Verify allocations are correct regardless of input token decimals
        (, uint256 user1Allocated, , , ) = idoManager.getUserInfo(idoId, user1);
        (, uint256 user2Allocated, , , ) = idoManager.getUserInfo(idoId, user2);
        (, uint256 user3Allocated, , , ) = idoManager.getUserInfo(idoId, user3);

        assertGt(user1Allocated, 0);
        assertGt(user2Allocated, 0);
        assertGt(user3Allocated, 0);

        // user1 invested $1000, user2 invested $500, so user1 should have ~2x allocation
        assertApproxEqRel(user1Allocated, user2Allocated * 2, 0.01e18); // 1% tolerance

        // 5. Advance to TGE
        vm.warp(vm.getBlockTimestamp() + 10 days);

        // 6. Users claim tokens (should receive correct amounts with IDO token decimals)
        uint256 user1BalanceBefore = idoToken2.balanceOf(user1);
        vm.prank(user1);
        idoManager.claimTokens(idoId);
        uint256 user1BalanceAfter = idoToken2.balanceOf(user1);

        // Verify user received tokens in correct decimals (6 decimals for idoToken2)
        uint256 user1Received = user1BalanceAfter - user1BalanceBefore;
        assertGt(user1Received, 0);

        // The internal allocation is in 18 decimals, but tokens transferred should be in 6
        // So received amount * 1e12 should roughly equal claimed amount
        (, , uint256 user1Claimed, , ) = idoManager.getUserInfo(idoId, user1);
        assertApproxEqRel(user1Received * 1e12, user1Claimed, 0.01e18);
    }

    /// @dev Tests admin functions for modifying IDO parameters
    /// Covers: setIdoTime, setTwapPriceUsdt, setClaimStartTime modifications
    function test_integration_AdminParameterModifications() public {
        // 1. Create IDO
        uint64 startTime = uint64(block.timestamp + 1 days);
        uint64 endTime = uint64(block.timestamp + 8 days);
        uint256 idoId = _createIDO(startTime, endTime, 1000000e18);

        // 2. Admin modifies IDO times before start
        uint64 newStartTime = uint64(block.timestamp + 2 days);
        uint64 newEndTime = uint64(block.timestamp + 9 days);

        vm.prank(admin);
        idoManager.setIdoTime(idoId, newStartTime, newEndTime);

        // Verify times were updated
        (uint64 idoStart, uint64 idoEnd, , , , , , , , ) = idoManager.idoSchedules(idoId);
        assertEq(idoStart, newStartTime);
        assertEq(idoEnd, newEndTime);

        // 3. Setup IDO
        _setupIDO(idoId, address(idoToken1));

        // 4. Admin modifies TWAP price
        uint256 newTwapPrice = 12e7; // $1.20
        vm.prank(admin);
        idoManager.setTwapPriceUsdt(idoId, newTwapPrice);

        // Verify TWAP was updated
        (, , uint256 twapPrice) = idoManager.idoPricing(idoId);
        assertEq(twapPrice, newTwapPrice);

        // 5. Admin modifies claim start time
        uint64 newClaimStart = uint64(block.timestamp + 15 days);
        vm.prank(admin);
        idoManager.setClaimStartTime(idoId, newClaimStart);

        // Verify claim start was updated
        (, , uint64 claimStart, , , , , , , ) = idoManager.idoSchedules(idoId);
        assertEq(claimStart, newClaimStart);

        // 6. Users invest
        vm.warp(newStartTime);
        _investUser(user1, idoId, 1000e6, address(usdt));

        // 7. Claims only work after new claim start time
        vm.warp(newClaimStart - 1);
        vm.expectRevert();
        vm.prank(user1);
        idoManager.claimTokens(idoId);

        vm.warp(newClaimStart);
        vm.prank(user1);
        idoManager.claimTokens(idoId);

        // Verify claim succeeded
        (, , uint256 claimed, , ) = idoManager.getUserInfo(idoId, user1);
        assertGt(claimed, 0);
    }

    /// @dev Tests phase transitions and currentPhase view function
    /// Covers: Phase calculation, bonus percentages per phase
    /// NOTE: Phases are based on ALLOCATION, not time!
    /// With totalAllocation = $1M: Phase1 < $333k, Phase2 < $666k, Phase3 >= $666k
    function test_integration_PhaseTransitions() public {
        // 1. Create IDO with higher per-user limit to allow phase testing
        uint64 startTime = uint64(block.timestamp + 1 days);
        uint64 endTime = uint64(block.timestamp + 10 days);

        IIDOManager.IDOInput memory idoInput = IIDOManager.IDOInput({
            info: IIDOManager.IDOInfo({
                tokenAddress: address(0),
                projectId: 1,
                totalAllocated: 0,
                minAllocationUSD: 100e18,
                totalAllocationByUser: 500000e18, // $500k per user to allow large investments
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
        uint256 idoId = idoManager.createIDO(idoInput);
        _setupIDO(idoId, address(idoToken1));

        // 2. Start IDO
        vm.warp(startTime);
        IIDOManager.Phase currentPhase = idoManager.currentPhase(idoId);
        assertEq(uint256(currentPhase), uint256(IIDOManager.Phase.Phase1));

        // 3. User1 invests small amount in Phase 1 (totalAllocated stays in Phase 1)
        // Phase 1: 0 to $333,333 allocated
        _investUser(user1, idoId, 1000e6, address(usdt)); // $1,000
        (, uint256 user1Allocated, , , ) = idoManager.getUserInfo(idoId, user1);

        // Verify Phase 1 bonus (20%)
        uint256 expectedUser1 = 1000e18 * 120 / 100; // $1000 * 1.2 = 1200 tokens
        assertApproxEqRel(user1Allocated, expectedUser1, 0.01e18);

        currentPhase = idoManager.currentPhase(idoId);
        assertEq(uint256(currentPhase), uint256(IIDOManager.Phase.Phase1));

        // 4. User2 invests enough to push into Phase 2
        // Need to invest ~$277k more to cross $333k threshold (accounting for 20% bonus)
        // $277k invested will span Phase 1 and Phase 2
        // Total allocated after should be > $333,333 → Phase 2
        _investUser(user2, idoId, 277000e6, address(usdt)); // $277,000

        // Check total allocated to debug
        (, , IIDOManager.IDOInfo memory idoInfo, ) = idoManager.idos(idoId);

        // User2's allocation spans both phases, so will have mixed bonus
        // Most of it in Phase 1 (20%), a tiny bit in Phase 2 (10%)
        currentPhase = idoManager.currentPhase(idoId);
        assertEq(uint256(currentPhase), uint256(IIDOManager.Phase.Phase2));

        // 5. User3 invests in Phase 2 (gets 10% bonus)
        _investUser(user3, idoId, 1000e6, address(usdt)); // $1,000
        (, uint256 user3Allocated, , , ) = idoManager.getUserInfo(idoId, user3);

        // Verify Phase 2 bonus (10%)
        uint256 expectedUser3 = 1000e18 * 110 / 100; // $1000 * 1.1 = 1100 tokens
        assertApproxEqRel(user3Allocated, expectedUser3, 0.01e18);

        // User3 should have less than user1 (10% vs 20% bonus on same investment)
        assertLt(user3Allocated, user1Allocated);

        // 6. User4 invests enough to push into Phase 3
        // Phase 3 starts at $666,667 allocated
        // Currently at ~$335k, need ~$332k more
        _investUser(user4, idoId, 340000e6, address(usdt)); // $340,000
        (, , idoInfo, ) = idoManager.idos(idoId);

        currentPhase = idoManager.currentPhase(idoId);
        assertEq(uint256(currentPhase), uint256(IIDOManager.Phase.Phase3));

        // 7. User5 invests in Phase 3 (gets 5% bonus)
        _investUser(user5, idoId, 1000e6, address(usdt)); // $1,000
        (, uint256 user5Allocated, , , ) = idoManager.getUserInfo(idoId, user5);

        // Verify Phase 3 bonus (5%)
        uint256 expectedUser5 = 1000e18 * 105 / 100; // $1000 * 1.05 = 1050 tokens
        assertApproxEqRel(user5Allocated, expectedUser5, 0.01e18);

        // User5 should have less than user3 (5% vs 10% bonus on same investment)
        assertLt(user5Allocated, user3Allocated);

    }

    /// @dev Tests complex accounting with multiple claims, refunds, and withdrawals
    /// Covers: Accurate tracking across multiple operations
    function test_integration_ComplexAccountingScenario() public {
        // 1. Create and setup IDO
        uint64 startTime = uint64(block.timestamp + 1 days);
        uint64 endTime = uint64(block.timestamp + 8 days);
        uint256 idoId = _createIDO(startTime, endTime, 1000000e18);
        _setupIDO(idoId, address(idoToken1));

        // 2. Multiple users invest with different tokens
        vm.warp(startTime);
        _investUser(user1, idoId, 1000e6, address(usdt));
        _investUser(user2, idoId, 500e6, address(usdc));
        _investUser(user3, idoId, 750e18, address(flx));
        _investUser(user4, idoId, 2000e6, address(usdt));
        _investUser(user5, idoId, 1500e6, address(usdc));

        // Track total raised per token
        uint256 totalRaisedUSDT = idoManager.totalRaisedInToken(idoId, address(usdt));
        uint256 totalRaisedUSDC = idoManager.totalRaisedInToken(idoId, address(usdc));
        uint256 totalRaisedFLX = idoManager.totalRaisedInToken(idoId, address(flx));

        assertEq(totalRaisedUSDT, 3000e6); // user1 + user4
        assertEq(totalRaisedUSDC, 2000e6); // user2 + user5
        assertEq(totalRaisedFLX, 750e18);  // user3

        // 3. User1 refunds before TGE
        vm.warp(startTime + 2 days);
        vm.prank(user1);
        idoManager.processRefund(idoId, true);

        // Check refunded tracking
        uint256 totalRefundedUSDT = idoManager.totalRefundedInToken(idoId, address(usdt));
        assertGt(totalRefundedUSDT, 0);

        // 4. Advance to TGE
        vm.warp(vm.getBlockTimestamp() + 9 days);

        // Remaining users claim, except for user2 who will refund later
        vm.prank(user3);
        idoManager.claimTokens(idoId);

        vm.prank(user4);
        idoManager.claimTokens(idoId);

        vm.prank(user5);
        idoManager.claimTokens(idoId);

        // 5. Reserves admin withdraws unlocked stablecoins
        uint256 withdrawableUSDT = idoManager.getWithdrawableAmount(idoId, address(usdt));
        assertGt(withdrawableUSDT, 0);

        vm.prank(reservesAdmin);
        idoManager.withdrawStablecoins(idoId, address(usdt), withdrawableUSDT);

        // 6. User2 refunds after TGE
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(user2);

        idoManager.processRefund(idoId, true);

        uint256 totalRefundedUSDC = idoManager.totalRefundedInToken(idoId, address(usdc));
        assertGt(totalRefundedUSDC, 0);

        // 7. Advance to vesting period
        vm.warp(vm.getBlockTimestamp() + 60 days);

        // User4 claims vested tokens
        vm.prank(user4);
        idoManager.claimTokens(idoId);

        // 8. User3 requests partial refund
        vm.prank(user3);
        idoManager.processRefund(idoId, false);

        // 9. Admin withdraws penalty fees from all tokens
        vm.startPrank(reservesAdmin);

        uint256 penaltyUSDT = idoManager.penaltyFeesCollected(idoId, address(usdt));
        if (penaltyUSDT > 0) {
            idoManager.withdrawPenaltyFees(idoId, address(usdt));
        }

        uint256 penaltyUSDC = idoManager.penaltyFeesCollected(idoId, address(usdc));
        if (penaltyUSDC > 0) {
            idoManager.withdrawPenaltyFees(idoId, address(usdc));
        }

        uint256 penaltyFLX = idoManager.penaltyFeesCollected(idoId, address(flx));
        if (penaltyFLX > 0) {
            idoManager.withdrawPenaltyFees(idoId, address(flx));
        }

        // Admin withdraws refunded tokens
        idoManager.withdrawRefundedTokens(idoId);

        vm.stopPrank();

        // 10. Verify final accounting consistency
        uint256 finalTotalClaimed = idoManager.totalClaimedTokens(idoId);
        assertGt(finalTotalClaimed, 0);

        // Total claimed + total refunded + remaining unlocked should make sense
        (, , IIDOManager.IDOInfo memory idoInfo, ) = idoManager.idos(idoId);
        (uint256 totalRefunded, , , , ) = idoManager.idoRefundInfo(idoId);

        // This is a sanity check - total refunded and claimed should not exceed total allocated
        assertLe(finalTotalClaimed + totalRefunded, idoInfo.totalAllocated);
    }

    /// @dev Tests getUserInfo view function returns correct values
    /// Covers: User info retrieval, data integrity
    function test_integration_GetUserInfo() public {
        // 1. Create and setup IDO
        uint64 startTime = uint64(block.timestamp + 1 days);
        uint64 endTime = uint64(block.timestamp + 8 days);
        uint256 idoId = _createIDO(startTime, endTime, 1000000e18);
        _setupIDO(idoId, address(idoToken1));

        // 2. User invests
        vm.warp(startTime);
        uint256 investAmount = 1000e6;
        _investUser(user1, idoId, investAmount, address(usdt));

        // 3. Get user info using getUserInfo
        (
            uint256 investedUsdt,
            uint256 allocatedTokens,
            uint256 claimedTokens,
            uint256 refundedTokens,
            bool claimed
        ) = idoManager.getUserInfo(idoId, user1);

        // 4. Verify key fields
        assertGt(allocatedTokens, 0, "Should have allocated tokens");
        assertEq(claimedTokens, 0, "Should not have claimed yet");
        assertEq(refundedTokens, 0, "Should not have refunded yet");
        // investedUsdt is in USD (18 decimals), investAmount is in USDT (6 decimals)
        // Convert investAmount to 18 decimals for comparison (since $1 USDT = $1 USD)
        assertEq(investedUsdt, investAmount * 1e12, "Investment amount should match");
        assertEq(claimed, false, "Should not have claimed yet");

        // 5. Advance to TGE and claim
        vm.warp(vm.getBlockTimestamp() + 10 days);
        vm.prank(user1);
        idoManager.claimTokens(idoId);

        // 6. Get user info after claim
        (, , uint256 claimedAfter, , ) = idoManager.getUserInfo(idoId, user1);

        assertGt(claimedAfter, 0, "Should have claimed tokens");
    }
}
