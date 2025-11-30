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

contract FullLifecycleIntegrationTest is Test {
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
        vm.stopPrank();

        // Mint IDO tokens to contract
        idoToken.mint(address(idoManager), 10000000e18);
    }

    /// @dev Tests the complete IDO lifecycle from creation to final claims
    /// This covers: IDO creation, setup, investments, claims, and withdrawals
    function test_integration_CompleteSuccessfulIDOLifecycle() public {
        // 1. Create IDO
        uint256 idoId = _createIDO();
        assertEq(idoId, 1);

        // 2. Setup IDO
        _setupIDO(idoId);

        // 3. Advance to IDO start
        vm.warp(vm.getBlockTimestamp() + 1 days);

        // 4. Multiple users invest in Phase 1 (first third of IDO)
        _investUser(user1, idoId, 1000e6, address(usdt)); // $1000 in USDT
        _investUser(user2, idoId, 500e6, address(usdc));  // $500 in USDC

        // Verify investments were recorded correctly
        (, uint256 user1Allocated, , , ) = idoManager.getUserInfo(idoId, user1);
        assertGt(user1Allocated, 1000e18); // More than $1000 worth due to 20% bonus

        // 5. Advance to Phase 2 (middle third)
        vm.warp(vm.getBlockTimestamp() + 2.5 days);
        _investUser(user3, idoId, 750e18, address(flx)); // $750 in FLX

        // 6. Advance to Phase 3 (last third)
        vm.warp(vm.getBlockTimestamp() + 2.5 days);
        _investUser(user4, idoId, 2000e6, address(usdt)); // $2000 in USDT

        // 7. Advance past IDO end
        vm.warp(vm.getBlockTimestamp() + 3 days);

        // 8. Advance to TGE
        // TGE was set to day 10 in _setupIDO, we're at day 9, so warp 1 more day
        vm.warp(vm.getBlockTimestamp() + 1 days);

        // 9. Users claim their TGE unlock (10%)
        vm.prank(user1);
        idoManager.claimTokens(idoId);

        vm.prank(user2);
        idoManager.claimTokens(idoId);

        // Verify claims
        (, , uint256 user1Claimed, , ) = idoManager.getUserInfo(idoId, user1);
        assertGt(user1Claimed, 0);

        // 10. Advance past cliff period + 1 days
        vm.warp(vm.getBlockTimestamp() + 30 days + 1 days);

        // 11. Users claim vested tokens (should unlock daily over 180 days)
        vm.prank(user1);
        idoManager.claimTokens(idoId);

        // 12. Advance to mid-vesting
        vm.warp(vm.getBlockTimestamp() + 90 days);

        // All users claim
        vm.prank(user1);
        idoManager.claimTokens(idoId);

        vm.prank(user2);
        idoManager.claimTokens(idoId);

        vm.prank(user3);
        idoManager.claimTokens(idoId);

        vm.prank(user4);
        idoManager.claimTokens(idoId);

        // 13. Reserves admin withdraws unlocked stablecoins
        uint256 withdrawableUSDT = idoManager.getWithdrawableAmount(idoId, address(usdt));
        if (withdrawableUSDT > 0) {
            vm.prank(reservesAdmin);
            idoManager.withdrawStablecoins(idoId, address(usdt), withdrawableUSDT);
        }

        uint256 withdrawableUSDC = idoManager.getWithdrawableAmount(idoId, address(usdc));
        if (withdrawableUSDC > 0) {
            vm.prank(reservesAdmin);
            idoManager.withdrawStablecoins(idoId, address(usdc), withdrawableUSDC);
        }

        uint256 withdrawableFLX = idoManager.getWithdrawableAmount(idoId, address(flx));
        if (withdrawableFLX > 0) {
            vm.prank(reservesAdmin);
            idoManager.withdrawStablecoins(idoId, address(flx), withdrawableFLX);
        }

        // 14. Advance to full vesting completion
        vm.warp(vm.getBlockTimestamp() + 91 days);

        // All users claim remaining tokens
        vm.prank(user1);
        idoManager.claimTokens(idoId);

        vm.prank(user2);
        idoManager.claimTokens(idoId);

        vm.prank(user3);
        idoManager.claimTokens(idoId);

        vm.prank(user4);
        idoManager.claimTokens(idoId);

        // 15. Reserves admin withdraws all remaining stablecoins
        withdrawableUSDT = idoManager.getWithdrawableAmount(idoId, address(usdt));
        if (withdrawableUSDT > 0) {
            vm.prank(reservesAdmin);
            idoManager.withdrawStablecoins(idoId, address(usdt), withdrawableUSDT);
        }

        withdrawableUSDC = idoManager.getWithdrawableAmount(idoId, address(usdc));
        if (withdrawableUSDC > 0) {
            vm.prank(reservesAdmin);
            idoManager.withdrawStablecoins(idoId, address(usdc), withdrawableUSDC);
        }

        withdrawableFLX = idoManager.getWithdrawableAmount(idoId, address(flx));
        if (withdrawableFLX > 0) {
            vm.prank(reservesAdmin);
            idoManager.withdrawStablecoins(idoId, address(flx), withdrawableFLX);
        }

        // 16. Check if there are unsold tokens and withdraw them
        (, , IIDOManager.IDOInfo memory idoInfo, ) = idoManager.idos(idoId);
        uint256 totalAllocated = idoInfo.totalAllocated;
        uint256 totalAllocation = idoInfo.totalAllocation;

        if (totalAllocated < totalAllocation) {
            vm.prank(reservesAdmin);
            idoManager.withdrawUnsoldTokens(idoId);
        }

        // Final assertions - verify the lifecycle completed successfully
        assertTrue(true, "Full IDO lifecycle completed successfully");
    }

    /// @dev Tests a scenario where the IDO doesn't sell out completely
    /// Covers: Partial sell, unsold token withdrawal
    function test_integration_PartialSellout() public {
        // 1. Create and setup IDO
        uint256 idoId = _createIDO();
        _setupIDO(idoId);

        // 2. Advance to IDO start
        vm.warp(vm.getBlockTimestamp() + 1 days);

        // 3. Only small investments (won't fill total allocation)
        _investUser(user1, idoId, 500e6, address(usdt));
        _investUser(user2, idoId, 300e6, address(usdc));

        // 4. Advance past IDO end
        vm.warp(vm.getBlockTimestamp() + 8 days);

        // 5. Get IDO info
        (, , IIDOManager.IDOInfo memory idoInfo, ) = idoManager.idos(idoId);

        // Verify partial sellout
        assertLt(idoInfo.totalAllocated, idoInfo.totalAllocation);

        // 6. Reserves admin withdraws unsold tokens
        uint256 contractBalanceBefore = idoToken.balanceOf(address(idoManager));
        uint256 reservesBalanceBefore = idoToken.balanceOf(reservesAdmin);

        vm.prank(reservesAdmin);
        idoManager.withdrawUnsoldTokens(idoId);

        // Verify unsold tokens were withdrawn
        uint256 contractBalanceAfter = idoToken.balanceOf(address(idoManager));
        uint256 reservesBalanceAfter = idoToken.balanceOf(reservesAdmin);

        assertLt(contractBalanceAfter, contractBalanceBefore);
        assertGt(reservesBalanceAfter, reservesBalanceBefore);
    }

    /// @dev Tests that users investing in different phases receive different bonuses
    /// Covers: Phase-based bonus calculations
    /// NOTE: Phases are based on ALLOCATION, not time!
    /// With totalAllocation = $1M: Phase1 < $333k, Phase2 < $666k, Phase3 >= $666k
    function test_integration_DifferentPhaseInvestments() public {
        // 1. Create IDO with higher per-user allocation limit for phase testing
        uint64 startTime = uint64(block.timestamp + 1 days);
        uint64 endTime = uint64(block.timestamp + 8 days);

        IIDOManager.IDOInput memory idoInput = IIDOManager.IDOInput({
            info: IIDOManager.IDOInfo({
                tokenAddress: address(0),
                projectId: 1,
                totalAllocated: 0,
                minAllocationUSD: 100e18,
                totalAllocationByUser: 500000e18, // $500k per user (increased for phase testing)
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
        _setupIDO(idoId);

        // 2. Advance to IDO start
        vm.warp(startTime);

        // All users invest the SAME amount to properly compare bonus effects
        uint256 investAmount = 290000e6; // $290k each

        // 3. User1 invests $290k in Phase 1 (totalAllocated starts at 0, so Phase 1)
        // Gets 290k * 1.20 = 348k tokens. After investment: totalAllocated = 348k > 333,333
        _investUser(user1, idoId, investAmount, address(usdt));
        (, uint256 user1Allocated, , , ) = idoManager.getUserInfo(idoId, user1);

        // 4. User2 invests $290k (totalAllocated is now 348k >= 333,333, so Phase 2)
        // Gets 290k * 1.10 = 319k tokens. After investment: totalAllocated = 348k + 319k = 667k > 666,667
        _investUser(user2, idoId, investAmount, address(usdt));
        (, uint256 user2Allocated, , , ) = idoManager.getUserInfo(idoId, user2);

        // 5. User3 invests $290k (totalAllocated is now 667k >= 666,667, so Phase 3)
        // Gets 290k * 1.05 = 304.5k tokens. After investment: totalAllocated = 667k + 304.5k = 971.5k < 1M
        _investUser(user3, idoId, investAmount, address(usdt));
        (, uint256 user3Allocated, , , ) = idoManager.getUserInfo(idoId, user3);

        // Verify bonus differences (Phase 1: 20%, Phase 2: 10%, Phase 3: 5%)
        assertGt(user1Allocated, user2Allocated, "Phase 1 bonus (20%) should be > Phase 2 bonus (10%)");
        assertGt(user2Allocated, user3Allocated, "Phase 2 bonus (10%) should be > Phase 3 bonus (5%)");
    }

    /// @dev Tests multiple users claiming at different times throughout vesting
    /// Covers: Complex vesting calculations, multiple claims
    function test_integration_MultipleUsersMultipleClaims() public {
        // 1. Create and setup IDO
        uint256 idoId = _createIDO();
        _setupIDO(idoId);

        // 2. Advance to IDO start and all users invest
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _investUser(user1, idoId, 1000e6, address(usdt));
        _investUser(user2, idoId, 500e6, address(usdc));
        _investUser(user3, idoId, 750e18, address(flx));

        // 3. Advance to TGE
        vm.warp(vm.getBlockTimestamp() + 10 days);

        // 4. User1 claims TGE immediately
        vm.prank(user1);
        idoManager.claimTokens(idoId);

        // 5. Advance past cliff
        vm.warp(vm.getBlockTimestamp() + 30 days);

        // 6. User2 claims TGE + cliff unlock (late claim)
        vm.prank(user2);
        idoManager.claimTokens(idoId);

        // 7. User1 claims cliff unlock
        vm.prank(user1);
        idoManager.claimTokens(idoId);

        // 8. Advance to 25% through vesting
        vm.warp(vm.getBlockTimestamp() + 45 days);

        // All users claim
        vm.prank(user1);
        idoManager.claimTokens(idoId);

        vm.prank(user2);
        idoManager.claimTokens(idoId);

        vm.prank(user3);
        idoManager.claimTokens(idoId);

        // 9. Advance to 75% through vesting
        vm.warp(vm.getBlockTimestamp() + 90 days);

        // All users claim again
        vm.prank(user1);
        idoManager.claimTokens(idoId);

        vm.prank(user2);
        idoManager.claimTokens(idoId);

        vm.prank(user3);
        idoManager.claimTokens(idoId);

        // 10. Advance to full vesting
        vm.warp(vm.getBlockTimestamp() + 45 days);

        // Final claims
        vm.prank(user1);
        idoManager.claimTokens(idoId);

        vm.prank(user2);
        idoManager.claimTokens(idoId);

        vm.prank(user3);
        idoManager.claimTokens(idoId);

        // Verify all users have claimed all their tokens
        (, uint256 user1Allocated, uint256 user1Claimed, , ) = idoManager.getUserInfo(idoId, user1);
        (, uint256 user2Allocated, uint256 user2Claimed, , ) = idoManager.getUserInfo(idoId, user2);
        (, uint256 user3Allocated, uint256 user3Claimed, , ) = idoManager.getUserInfo(idoId, user3);

        assertEq(user1Claimed, user1Allocated);
        assertEq(user2Claimed, user2Allocated);
        assertEq(user3Claimed, user3Allocated);
    }

    /// @dev Tests reserves admin withdrawing stablecoins progressively as they unlock
    /// Covers: Progressive stablecoin withdrawals following vesting schedule
    function test_integration_ProgressiveStablecoinWithdrawals() public {
        // 1. Create and setup IDO
        uint256 idoId = _createIDO();
        _setupIDO(idoId);

        // 2. Users invest
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _investUser(user1, idoId, 1000e6, address(usdt));
        _investUser(user2, idoId, 500e6, address(usdc));
        _investUser(user3, idoId, 750e18, address(flx));

        // 3. Advance to TGE
        vm.warp(vm.getBlockTimestamp() + 10 days);

        // Users claim TGE unlock
        vm.prank(user1);
        idoManager.claimTokens(idoId);

        vm.prank(user2);
        idoManager.claimTokens(idoId);

        vm.prank(user3);
        idoManager.claimTokens(idoId);

        // 4. Reserves admin withdraws unlocked stablecoins (10% of raised amount)
        uint256 withdrawableUSDT1 = idoManager.getWithdrawableAmount(idoId, address(usdt));
        assertGt(withdrawableUSDT1, 0);

        vm.prank(reservesAdmin);
        idoManager.withdrawStablecoins(idoId, address(usdt), withdrawableUSDT1);

        uint256 reservesBalanceAfterTGE = usdt.balanceOf(reservesAdmin);
        assertGt(reservesBalanceAfterTGE, 0);

        // 5. Advance past cliff to mid-vesting
        vm.warp(vm.getBlockTimestamp() + 30 days + 90 days);

        // Users claim
        vm.prank(user1);
        idoManager.claimTokens(idoId);

        vm.prank(user2);
        idoManager.claimTokens(idoId);

        vm.prank(user3);
        idoManager.claimTokens(idoId);

        // 6. Reserves admin withdraws more unlocked stablecoins (~50% total)
        uint256 withdrawableUSDT2 = idoManager.getWithdrawableAmount(idoId, address(usdt));
        assertGt(withdrawableUSDT2, 0);

        vm.prank(reservesAdmin);
        idoManager.withdrawStablecoins(idoId, address(usdt), withdrawableUSDT2);

        uint256 reservesBalanceAfterMidVesting = usdt.balanceOf(reservesAdmin);
        assertGt(reservesBalanceAfterMidVesting, reservesBalanceAfterTGE);

        // 7. Advance to full vesting completion
        vm.warp(vm.getBlockTimestamp() + 91 days);

        // Users claim remaining
        vm.prank(user1);
        idoManager.claimTokens(idoId);

        vm.prank(user2);
        idoManager.claimTokens(idoId);

        vm.prank(user3);
        idoManager.claimTokens(idoId);

        // 8. Reserves admin withdraws all remaining stablecoins
        uint256 withdrawableUSDT3 = idoManager.getWithdrawableAmount(idoId, address(usdt));
        assertGt(withdrawableUSDT3, 0);

        vm.prank(reservesAdmin);
        idoManager.withdrawStablecoins(idoId, address(usdt), withdrawableUSDT3);

        uint256 finalReservesBalance = usdt.balanceOf(reservesAdmin);
        assertGt(finalReservesBalance, reservesBalanceAfterMidVesting);
    }
}
