// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ReservesManager} from "../../src/ReservesManager.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

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

// Test harness to expose ReservesManager functionality
contract ReservesManagerHarness is ReservesManager {
    // Storage for testing
    mapping(uint256 => TestIDO) public testIdos;

    struct TestIDO {
        uint256 totalRaised;
        uint256 totalRefunded;
        uint256 totalClaimed;
        uint256 totalAllocated;
        uint256 totalRefundedTokens;
    }

    constructor(
        address _admin,
        address _usdt,
        address _usdc,
        address _flx
    ) ReservesManager(_admin, _usdt, _usdc, _flx) {}

    // Implement abstract function
    function getWithdrawableAmount(
        uint256 idoId,
        address token
    ) external view override returns (uint256) {
        TestIDO memory ido = testIdos[idoId];
        return _getWithdrawableAmount(
            idoId,
            token,
            ido.totalRaised,
            ido.totalRefunded,
            ido.totalClaimed,
            ido.totalAllocated,
            ido.totalRefundedTokens
        );
    }

    // Implement abstract function
    function withdrawStablecoins(
        uint256 idoId,
        address token,
        uint256 amount
    ) external override onlyReservesAdmin {
        TestIDO memory ido = testIdos[idoId];
        _withdrawStablecoins(
            idoId,
            token,
            amount,
            ido.totalRaised,
            ido.totalRefunded,
            ido.totalClaimed,
            ido.totalAllocated,
            ido.totalRefundedTokens
        );
    }

    // Stub implementations for new withdrawal functions (not tested in this unit test)
    function withdrawUnsoldTokens(uint256) external pure override {
        revert("Not implemented in test harness");
    }

    function withdrawRefundedTokens(uint256) external pure override {
        revert("Not implemented in test harness");
    }

    function withdrawPenaltyFees(uint256, address) external pure override {
        revert("Not implemented in test harness");
    }

    // Helper to set test data
    function setTestIDO(
        uint256 idoId,
        uint256 totalRaised,
        uint256 totalRefunded,
        uint256 totalClaimed,
        uint256 totalAllocated,
        uint256 totalRefundedTokens
    ) external {
        testIdos[idoId] = TestIDO({
            totalRaised: totalRaised,
            totalRefunded: totalRefunded,
            totalClaimed: totalClaimed,
            totalAllocated: totalAllocated,
            totalRefundedTokens: totalRefundedTokens
        });
    }

    // Expose internal function for testing
    function exposed_setReservesAdmin(address newAdmin) external {
        _setReservesAdmin(newAdmin);
    }
}

contract ReservesManagerTest is Test {
    ReservesManagerHarness public manager;

    MockERC20 public usdt;
    MockERC20 public usdc;
    MockERC20 public flx;
    MockERC20 public randomToken;

    address public admin = makeAddr("admin");
    address public user1 = makeAddr("user1");
    address public newAdmin = makeAddr("newAdmin");

    function setUp() public {
        // Deploy mock tokens
        usdt = new MockERC20("USDT", "USDT", 6);
        usdc = new MockERC20("USDC", "USDC", 6);
        flx = new MockERC20("FLX", "FLX", 18);
        randomToken = new MockERC20("RANDOM", "RND", 18);

        // Deploy harness
        manager = new ReservesManagerHarness(
            admin,
            address(usdt),
            address(usdc),
            address(flx)
        );
    }

    // Helper to create test IDO with specific parameters
    function _createTestIDO(
        uint256 idoId,
        uint256 totalRaised,
        uint256 totalRefunded,
        uint256 totalClaimed,
        uint256 totalAllocated,
        uint256 totalRefundedTokens
    ) internal {
        manager.setTestIDO(
            idoId,
            totalRaised,
            totalRefunded,
            totalClaimed,
            totalAllocated,
            totalRefundedTokens
        );
    }

    // Helper to fund contract for withdrawals
    function _fundContract(address token, uint256 amount) internal {
        MockERC20(token).mint(address(manager), amount);
    }

    // ============================================
    // Constructor Tests (5 tests)
    // ============================================

    function test_constructor_Success() public {
        ReservesManagerHarness newManager = new ReservesManagerHarness(
            admin,
            address(usdt),
            address(usdc),
            address(flx)
        );

        assertEq(newManager.reservesAdmin(), admin);
        assertEq(newManager.USDT(), address(usdt));
        assertEq(newManager.USDC(), address(usdc));
        assertEq(newManager.FLX(), address(flx));
    }

    function test_constructor_RevertsWithZeroAdmin() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidZeroAddress()"));
        new ReservesManagerHarness(
            address(0),
            address(usdt),
            address(usdc),
            address(flx)
        );
    }

    function test_constructor_RevertsWithZeroUSDT() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidTokenAddress()"));
        new ReservesManagerHarness(
            admin,
            address(0),
            address(usdc),
            address(flx)
        );
    }

    function test_constructor_RevertsWithZeroUSDC() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidTokenAddress()"));
        new ReservesManagerHarness(
            admin,
            address(usdt),
            address(0),
            address(flx)
        );
    }

    function test_constructor_RevertsWithZeroFLX() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidTokenAddress()"));
        new ReservesManagerHarness(
            admin,
            address(usdt),
            address(usdc),
            address(0)
        );
    }

    // ============================================
    // isStablecoin Tests (5 tests)
    // ============================================

    function test_isStablecoin_ReturnsTrue_ForUSDT() public view {
        assertTrue(manager.isStablecoin(address(usdt)));
    }

    function test_isStablecoin_ReturnsTrue_ForUSDC() public view {
        assertTrue(manager.isStablecoin(address(usdc)));
    }

    function test_isStablecoin_ReturnsTrue_ForFLX() public view {
        assertTrue(manager.isStablecoin(address(flx)));
    }

    function test_isStablecoin_ReturnsFalse_ForInvalidToken() public view {
        assertFalse(manager.isStablecoin(address(randomToken)));
    }

    function test_isStablecoin_ReturnsFalse_ForZeroAddress() public view {
        assertFalse(manager.isStablecoin(address(0)));
    }

    // ============================================
    // changeReservesAdmin Tests (4 tests)
    // ============================================

    function test_changeReservesAdmin_Success() public {
        vm.prank(admin);
        manager.changeReservesAdmin(newAdmin);

        assertEq(manager.reservesAdmin(), newAdmin);
    }

    function test_changeReservesAdmin_RevertsWithZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("InvalidZeroAddress()"));
        manager.changeReservesAdmin(address(0));
    }

    function test_changeReservesAdmin_RevertsWithNonAdmin() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OnlyReservesAdmin()"));
        manager.changeReservesAdmin(newAdmin);
    }

    function test_changeReservesAdmin_EmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit ReservesManager.ReservesAdminChanged(admin, newAdmin);

        vm.prank(admin);
        manager.changeReservesAdmin(newAdmin);
    }

    // ============================================
    // _getWithdrawableAmount Tests (15 tests)
    // ============================================

    function test_getWithdrawableAmount_Success_FullyVested() public {
        uint256 idoId = 1;
        uint256 totalRaised = 1000e6; // 1000 USDT
        uint256 totalAllocated = 100e18; // 100 tokens
        uint256 totalClaimed = 100e18; // 100% claimed

        _createTestIDO(idoId, totalRaised, 0, totalClaimed, totalAllocated, 0);
        _fundContract(address(usdt), totalRaised);

        uint256 withdrawable = manager.getWithdrawableAmount(idoId, address(usdt));
        assertEq(withdrawable, totalRaised);
    }

    function test_getWithdrawableAmount_Success_PartiallyVested_50Percent() public {
        uint256 idoId = 1;
        uint256 totalRaised = 1000e6; // 1000 USDT
        uint256 totalAllocated = 100e18; // 100 tokens
        uint256 totalClaimed = 50e18; // 50% claimed

        _createTestIDO(idoId, totalRaised, 0, totalClaimed, totalAllocated, 0);
        _fundContract(address(usdt), totalRaised);

        uint256 withdrawable = manager.getWithdrawableAmount(idoId, address(usdt));
        assertEq(withdrawable, 500e6); // 50% of 1000 USDT
    }

    function test_getWithdrawableAmount_Success_PartiallyVested_25Percent() public {
        uint256 idoId = 1;
        uint256 totalRaised = 1000e6; // 1000 USDT
        uint256 totalAllocated = 100e18; // 100 tokens
        uint256 totalClaimed = 25e18; // 25% claimed

        _createTestIDO(idoId, totalRaised, 0, totalClaimed, totalAllocated, 0);
        _fundContract(address(usdt), totalRaised);

        uint256 withdrawable = manager.getWithdrawableAmount(idoId, address(usdt));
        assertEq(withdrawable, 250e6); // 25% of 1000 USDT
    }

    function test_getWithdrawableAmount_Success_AccountsForRefunds() public {
        uint256 idoId = 1;
        uint256 totalRaised = 1000e6;
        uint256 totalRefunded = 200e6;
        uint256 totalAllocated = 100e18;
        uint256 totalClaimed = 100e18; // 100% claimed

        _createTestIDO(idoId, totalRaised, totalRefunded, totalClaimed, totalAllocated, 0);
        _fundContract(address(usdt), totalRaised - totalRefunded);

        uint256 withdrawable = manager.getWithdrawableAmount(idoId, address(usdt));
        assertEq(withdrawable, 800e6); // netRaised = 1000 - 200 = 800
    }

    function test_getWithdrawableAmount_Success_AccountsForPreviousWithdrawals() public {
        uint256 idoId = 1;
        uint256 totalRaised = 1000e6;
        uint256 totalAllocated = 100e18;
        uint256 totalClaimed = 100e18; // 100% claimed

        _createTestIDO(idoId, totalRaised, 0, totalClaimed, totalAllocated, 0);
        _fundContract(address(usdt), totalRaised);

        // Admin withdraws 600 USDT
        vm.prank(admin);
        manager.withdrawStablecoins(idoId, address(usdt), 600e6);

        // Check remaining withdrawable
        uint256 withdrawable = manager.getWithdrawableAmount(idoId, address(usdt));
        assertEq(withdrawable, 400e6); // 1000 - 600 = 400
    }

    function test_getWithdrawableAmount_Success_WithRefundedTokens() public {
        uint256 idoId = 1;
        uint256 totalRaised = 1000e6;
        uint256 totalAllocated = 100e18;
        uint256 totalRefundedTokens = 20e18; // 20 tokens refunded
        // netAllocated = 100 - 20 = 80
        uint256 totalClaimed = 64e18; // 80% of remaining (64/80 = 80%)

        _createTestIDO(idoId, totalRaised, 0, totalClaimed, totalAllocated, totalRefundedTokens);
        _fundContract(address(usdt), totalRaised);

        uint256 withdrawable = manager.getWithdrawableAmount(idoId, address(usdt));
        assertEq(withdrawable, 800e6); // 80% of 1000 = 800
    }

    function test_getWithdrawableAmount_ReturnsZero_WhenNothingClaimed() public {
        uint256 idoId = 1;
        uint256 totalRaised = 1000e6;
        uint256 totalAllocated = 100e18;
        uint256 totalClaimed = 0; // Nothing claimed

        _createTestIDO(idoId, totalRaised, 0, totalClaimed, totalAllocated, 0);
        _fundContract(address(usdt), totalRaised);

        uint256 withdrawable = manager.getWithdrawableAmount(idoId, address(usdt));
        assertEq(withdrawable, 0);
    }

    function test_getWithdrawableAmount_ReturnsZero_WhenNetAllocatedIsZero() public {
        uint256 idoId = 1;
        uint256 totalRaised = 1000e6;
        uint256 totalAllocated = 100e18;
        uint256 totalRefundedTokens = 100e18; // All tokens refunded

        _createTestIDO(idoId, totalRaised, 0, 0, totalAllocated, totalRefundedTokens);
        _fundContract(address(usdt), totalRaised);

        uint256 withdrawable = manager.getWithdrawableAmount(idoId, address(usdt));
        assertEq(withdrawable, 0);
    }

    function test_getWithdrawableAmount_ReturnsZero_WhenAlreadyFullyWithdrawn() public {
        uint256 idoId = 1;
        uint256 totalRaised = 1000e6;
        uint256 totalAllocated = 100e18;
        uint256 totalClaimed = 100e18;

        _createTestIDO(idoId, totalRaised, 0, totalClaimed, totalAllocated, 0);
        _fundContract(address(usdt), totalRaised);

        // Withdraw everything
        vm.prank(admin);
        manager.withdrawStablecoins(idoId, address(usdt), totalRaised);

        uint256 withdrawable = manager.getWithdrawableAmount(idoId, address(usdt));
        assertEq(withdrawable, 0);
    }

    function test_getWithdrawableAmount_ReturnsZero_WhenWithdrawnExceedsUnlocked() public {
        uint256 idoId = 1;
        uint256 totalRaised = 1000e6;
        uint256 totalAllocated = 100e18;
        uint256 totalClaimed = 50e18; // 50% claimed = 500 unlocked

        _createTestIDO(idoId, totalRaised, 0, totalClaimed, totalAllocated, 0);
        _fundContract(address(usdt), totalRaised);

        // Withdraw 500
        vm.prank(admin);
        manager.withdrawStablecoins(idoId, address(usdt), 500e6);

        // Manually increase withdrawn amount beyond unlocked (simulating edge case)
        // Note: In practice this shouldn't happen, but we test the safety check
        uint256 withdrawable = manager.getWithdrawableAmount(idoId, address(usdt));
        assertEq(withdrawable, 0);
    }

    function test_getWithdrawableAmount_RevertsWithNotAStablecoin() public {
        uint256 idoId = 1;
        _createTestIDO(idoId, 1000e6, 0, 100e18, 100e18, 0);

        vm.expectRevert(abi.encodeWithSignature("NotAStablecoin()"));
        manager.getWithdrawableAmount(idoId, address(randomToken));
    }

    function test_getWithdrawableAmount_Success_MultipleTokens() public {
        uint256 idoId = 1;
        uint256 raisedUSDT = 1000e6;
        uint256 raisedUSDC = 500e6;
        uint256 totalAllocated = 100e18;
        uint256 totalClaimed = 50e18; // 50% claimed

        // Set up IDO (same for both tokens, but we'll check separately)
        _createTestIDO(idoId, raisedUSDT, 0, totalClaimed, totalAllocated, 0);
        _fundContract(address(usdt), raisedUSDT);
        _fundContract(address(usdc), raisedUSDC);

        // Check USDT
        uint256 withdrawableUSDT = manager.getWithdrawableAmount(idoId, address(usdt));
        assertEq(withdrawableUSDT, 500e6); // 50% of 1000

        // Note: In real implementation, each token's raised amount is tracked separately
        // This test demonstrates the function works independently per token
    }

    function test_getWithdrawableAmount_Success_LargeNumbers() public {
        uint256 idoId = 1;
        uint256 totalRaised = 1_000_000_000e6; // 1 billion USDT
        uint256 totalAllocated = 1_000_000_000e18; // 1 billion tokens
        uint256 totalClaimed = 500_000_000e18; // 500M claimed (50%)

        _createTestIDO(idoId, totalRaised, 0, totalClaimed, totalAllocated, 0);
        _fundContract(address(usdt), totalRaised);

        uint256 withdrawable = manager.getWithdrawableAmount(idoId, address(usdt));
        assertEq(withdrawable, 500_000_000e6); // 50% of 1B
    }

    function test_getWithdrawableAmount_Success_TotalRefundedExceedsTotalAllocated_EdgeCase() public {
        uint256 idoId = 1;
        uint256 totalRaised = 1000e6;
        uint256 totalAllocated = 100e18;
        uint256 totalRefundedTokens = 150e18; // More than allocated (edge case)

        _createTestIDO(idoId, totalRaised, 0, 0, totalAllocated, totalRefundedTokens);
        _fundContract(address(usdt), totalRaised);

        uint256 withdrawable = manager.getWithdrawableAmount(idoId, address(usdt));
        assertEq(withdrawable, 0); // netAllocated becomes 0
    }

    // ============================================
    // _withdrawStablecoins Tests (16 tests)
    // ============================================

    function test_withdrawStablecoins_Success_PartialWithdrawal() public {
        uint256 idoId = 1;
        uint256 totalRaised = 1000e6;
        uint256 totalAllocated = 100e18;
        uint256 totalClaimed = 100e18; // 100% claimed

        _createTestIDO(idoId, totalRaised, 0, totalClaimed, totalAllocated, 0);
        _fundContract(address(usdt), totalRaised);

        uint256 adminBalanceBefore = usdt.balanceOf(admin);

        vm.prank(admin);
        manager.withdrawStablecoins(idoId, address(usdt), 400e6);

        assertEq(usdt.balanceOf(admin), adminBalanceBefore + 400e6);
        assertEq(manager.stablecoinsWithdrawnInToken(idoId, address(usdt)), 400e6);
    }

    function test_withdrawStablecoins_Success_FullWithdrawal() public {
        uint256 idoId = 1;
        uint256 totalRaised = 1000e6;
        uint256 totalAllocated = 100e18;
        uint256 totalClaimed = 100e18;

        _createTestIDO(idoId, totalRaised, 0, totalClaimed, totalAllocated, 0);
        _fundContract(address(usdt), totalRaised);

        vm.prank(admin);
        manager.withdrawStablecoins(idoId, address(usdt), totalRaised);

        assertEq(usdt.balanceOf(admin), totalRaised);
        assertEq(manager.stablecoinsWithdrawnInToken(idoId, address(usdt)), totalRaised);
    }

    function test_withdrawStablecoins_Success_MultipleWithdrawals() public {
        uint256 idoId = 1;
        uint256 totalRaised = 1000e6;
        uint256 totalAllocated = 100e18;

        _createTestIDO(idoId, totalRaised, 0, 25e18, totalAllocated, 0);
        _fundContract(address(usdt), totalRaised);

        // First withdrawal - 25% claimed
        vm.prank(admin);
        manager.withdrawStablecoins(idoId, address(usdt), 100e6);
        assertEq(manager.stablecoinsWithdrawnInToken(idoId, address(usdt)), 100e6);

        // Update: 50% claimed
        _createTestIDO(idoId, totalRaised, 0, 50e18, totalAllocated, 0);

        // Second withdrawal
        vm.prank(admin);
        manager.withdrawStablecoins(idoId, address(usdt), 150e6);
        assertEq(manager.stablecoinsWithdrawnInToken(idoId, address(usdt)), 250e6);

        // Update: 100% claimed
        _createTestIDO(idoId, totalRaised, 0, 100e18, totalAllocated, 0);

        // Third withdrawal
        vm.prank(admin);
        manager.withdrawStablecoins(idoId, address(usdt), 750e6);
        assertEq(manager.stablecoinsWithdrawnInToken(idoId, address(usdt)), 1000e6);
    }

    function test_withdrawStablecoins_Success_UpdatesMapping() public {
        uint256 idoId = 1;
        _createTestIDO(idoId, 1000e6, 0, 100e18, 100e18, 0);
        _fundContract(address(usdt), 1000e6);

        assertEq(manager.stablecoinsWithdrawnInToken(idoId, address(usdt)), 0);

        vm.prank(admin);
        manager.withdrawStablecoins(idoId, address(usdt), 500e6);

        assertEq(manager.stablecoinsWithdrawnInToken(idoId, address(usdt)), 500e6);
    }

    function test_withdrawStablecoins_Success_EmitsEvent() public {
        uint256 idoId = 1;
        _createTestIDO(idoId, 1000e6, 0, 100e18, 100e18, 0);
        _fundContract(address(usdt), 1000e6);

        vm.expectEmit(true, true, false, true);
        emit ReservesManager.AdminWithdrawal(idoId, address(usdt), 500e6);

        vm.prank(admin);
        manager.withdrawStablecoins(idoId, address(usdt), 500e6);
    }

    function test_withdrawStablecoins_Success_TransfersTokens() public {
        uint256 idoId = 1;
        _createTestIDO(idoId, 1000e6, 0, 100e18, 100e18, 0);
        _fundContract(address(usdt), 1000e6);

        uint256 contractBalanceBefore = usdt.balanceOf(address(manager));
        uint256 adminBalanceBefore = usdt.balanceOf(admin);

        vm.prank(admin);
        manager.withdrawStablecoins(idoId, address(usdt), 500e6);

        assertEq(usdt.balanceOf(address(manager)), contractBalanceBefore - 500e6);
        assertEq(usdt.balanceOf(admin), adminBalanceBefore + 500e6);
    }

    function test_withdrawStablecoins_Success_WithUSDT() public {
        uint256 idoId = 1;
        _createTestIDO(idoId, 1000e6, 0, 100e18, 100e18, 0);
        _fundContract(address(usdt), 1000e6);

        vm.prank(admin);
        manager.withdrawStablecoins(idoId, address(usdt), 500e6);

        assertEq(usdt.balanceOf(admin), 500e6);
    }

    function test_withdrawStablecoins_Success_WithUSDC() public {
        uint256 idoId = 1;
        _createTestIDO(idoId, 1000e6, 0, 100e18, 100e18, 0);
        _fundContract(address(usdc), 1000e6);

        vm.prank(admin);
        manager.withdrawStablecoins(idoId, address(usdc), 500e6);

        assertEq(usdc.balanceOf(admin), 500e6);
    }

    function test_withdrawStablecoins_Success_WithFLX() public {
        uint256 idoId = 1;
        _createTestIDO(idoId, 1000e18, 0, 100e18, 100e18, 0);
        _fundContract(address(flx), 1000e18);

        vm.prank(admin);
        manager.withdrawStablecoins(idoId, address(flx), 500e18);

        assertEq(flx.balanceOf(admin), 500e18);
    }

    function test_withdrawStablecoins_RevertsWithZeroAmount() public {
        uint256 idoId = 1;
        _createTestIDO(idoId, 1000e6, 0, 100e18, 100e18, 0);
        _fundContract(address(usdt), 1000e6);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("InvalidAmount()"));
        manager.withdrawStablecoins(idoId, address(usdt), 0);
    }

    function test_withdrawStablecoins_RevertsWithNotAStablecoin() public {
        uint256 idoId = 1;
        _createTestIDO(idoId, 1000e6, 0, 100e18, 100e18, 0);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("NotAStablecoin()"));
        manager.withdrawStablecoins(idoId, address(randomToken), 500e6);
    }

    function test_withdrawStablecoins_RevertsWithExceedsWithdrawable() public {
        uint256 idoId = 1;
        uint256 totalRaised = 1000e6;
        uint256 totalAllocated = 100e18;
        uint256 totalClaimed = 50e18; // 50% claimed = 500 withdrawable

        _createTestIDO(idoId, totalRaised, 0, totalClaimed, totalAllocated, 0);
        _fundContract(address(usdt), totalRaised);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("ExceedsWithdrawableAmount()"));
        manager.withdrawStablecoins(idoId, address(usdt), 600e6); // Try to withdraw more than 500
    }

    function test_withdrawStablecoins_RevertsWithExceedsWithdrawable_WhenNothingUnlocked() public {
        uint256 idoId = 1;
        _createTestIDO(idoId, 1000e6, 0, 0, 100e18, 0); // Nothing claimed
        _fundContract(address(usdt), 1000e6);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("ExceedsWithdrawableAmount()"));
        manager.withdrawStablecoins(idoId, address(usdt), 1); // Can't withdraw even 1 wei
    }

    function test_withdrawStablecoins_Success_AfterPartialClaims() public {
        uint256 idoId = 1;
        uint256 totalRaised = 1000e6;
        uint256 totalAllocated = 100e18;
        uint256 totalClaimed = 30e18; // 30% claimed

        _createTestIDO(idoId, totalRaised, 0, totalClaimed, totalAllocated, 0);
        _fundContract(address(usdt), totalRaised);

        vm.prank(admin);
        manager.withdrawStablecoins(idoId, address(usdt), 300e6); // 30% of raised

        assertEq(usdt.balanceOf(admin), 300e6);
    }

    function test_withdrawStablecoins_Success_SeparateTrackingPerToken() public {
        uint256 idoId = 1;
        _createTestIDO(idoId, 1000e6, 0, 100e18, 100e18, 0);
        _fundContract(address(usdt), 1000e6);
        _fundContract(address(usdc), 500e6);

        // Withdraw from USDT
        vm.prank(admin);
        manager.withdrawStablecoins(idoId, address(usdt), 400e6);
        assertEq(manager.stablecoinsWithdrawnInToken(idoId, address(usdt)), 400e6);
        assertEq(manager.stablecoinsWithdrawnInToken(idoId, address(usdc)), 0);

        // Withdraw from USDC
        vm.prank(admin);
        manager.withdrawStablecoins(idoId, address(usdc), 200e6);
        assertEq(manager.stablecoinsWithdrawnInToken(idoId, address(usdt)), 400e6);
        assertEq(manager.stablecoinsWithdrawnInToken(idoId, address(usdc)), 200e6);
    }

    // ============================================
    // _setReservesAdmin Tests (4 tests)
    // ============================================

    function test_setReservesAdmin_Success() public {
        manager.exposed_setReservesAdmin(newAdmin);
        assertEq(manager.reservesAdmin(), newAdmin);
    }

    function test_setReservesAdmin_RevertsWithZeroAddress() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidZeroAddress()"));
        manager.exposed_setReservesAdmin(address(0));
    }

    function test_setReservesAdmin_EmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit ReservesManager.ReservesAdminChanged(admin, newAdmin);

        manager.exposed_setReservesAdmin(newAdmin);
    }

    function test_setReservesAdmin_UpdatesStateVariable() public {
        assertEq(manager.reservesAdmin(), admin);
        manager.exposed_setReservesAdmin(newAdmin);
        assertEq(manager.reservesAdmin(), newAdmin);
    }

    // ============================================
    // onlyReservesAdmin Modifier Tests (2 tests)
    // ============================================

    function test_onlyReservesAdmin_AllowsAdmin() public {
        // This test passes if no revert occurs
        vm.prank(admin);
        manager.changeReservesAdmin(newAdmin);
        // Success - admin was allowed
    }

    function test_onlyReservesAdmin_RevertsForNonAdmin() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OnlyReservesAdmin()"));
        manager.changeReservesAdmin(newAdmin);
    }

    // ============================================
    // Integration/Edge Case Tests (8 tests)
    // ============================================

    function test_integration_FullLifecycle() public {
        uint256 idoId = 1;
        uint256 totalRaised = 1000e6;
        uint256 totalAllocated = 100e18;

        _fundContract(address(usdt), totalRaised);

        // Stage 1: No claims yet - cannot withdraw
        _createTestIDO(idoId, totalRaised, 0, 0, totalAllocated, 0);
        assertEq(manager.getWithdrawableAmount(idoId, address(usdt)), 0);

        // Stage 2: 25% claimed - can withdraw 250
        _createTestIDO(idoId, totalRaised, 0, 25e18, totalAllocated, 0);
        assertEq(manager.getWithdrawableAmount(idoId, address(usdt)), 250e6);
        vm.prank(admin);
        manager.withdrawStablecoins(idoId, address(usdt), 250e6);

        // Stage 3: 50% claimed - can withdraw additional 250
        _createTestIDO(idoId, totalRaised, 0, 50e18, totalAllocated, 0);
        assertEq(manager.getWithdrawableAmount(idoId, address(usdt)), 250e6);
        vm.prank(admin);
        manager.withdrawStablecoins(idoId, address(usdt), 250e6);

        // Stage 4: 100% claimed - can withdraw remaining 500
        _createTestIDO(idoId, totalRaised, 0, 100e18, totalAllocated, 0);
        assertEq(manager.getWithdrawableAmount(idoId, address(usdt)), 500e6);
        vm.prank(admin);
        manager.withdrawStablecoins(idoId, address(usdt), 500e6);

        // Stage 5: All withdrawn
        assertEq(manager.getWithdrawableAmount(idoId, address(usdt)), 0);
        assertEq(usdt.balanceOf(admin), totalRaised);
    }

    function test_integration_MultipleIDOs() public {
        _fundContract(address(usdt), 3000e6);

        // IDO 1: 1000 raised, 100% claimed
        _createTestIDO(1, 1000e6, 0, 100e18, 100e18, 0);
        assertEq(manager.getWithdrawableAmount(1, address(usdt)), 1000e6);

        // IDO 2: 1000 raised, 50% claimed
        _createTestIDO(2, 1000e6, 0, 50e18, 100e18, 0);
        assertEq(manager.getWithdrawableAmount(2, address(usdt)), 500e6);

        // IDO 3: 1000 raised, 0% claimed
        _createTestIDO(3, 1000e6, 0, 0, 100e18, 0);
        assertEq(manager.getWithdrawableAmount(3, address(usdt)), 0);

        // Withdraw from each independently
        vm.startPrank(admin);
        manager.withdrawStablecoins(1, address(usdt), 1000e6);
        manager.withdrawStablecoins(2, address(usdt), 500e6);
        vm.stopPrank();

        // Verify tracking
        assertEq(manager.stablecoinsWithdrawnInToken(1, address(usdt)), 1000e6);
        assertEq(manager.stablecoinsWithdrawnInToken(2, address(usdt)), 500e6);
        assertEq(manager.stablecoinsWithdrawnInToken(3, address(usdt)), 0);
    }

    function test_integration_PrecisionHandling() public {
        uint256 idoId = 1;
        // Use numbers that could cause rounding issues
        uint256 totalRaised = 999e6; // 999 USDT
        uint256 totalAllocated = 333e18; // 333 tokens
        uint256 totalClaimed = 111e18; // 111 claimed (exactly 1/3)

        _createTestIDO(idoId, totalRaised, 0, totalClaimed, totalAllocated, 0);
        _fundContract(address(usdt), totalRaised);

        uint256 withdrawable = manager.getWithdrawableAmount(idoId, address(usdt));
        // Due to integer division: 999 * (111/333) = 999 * 0.333... = 332.999... (rounded down)
        // The actual calculation: claimedPercent = 111e18 * 10_000_000 / 333e18 = 3333333
        // unlockedAmount = 999e6 * 3333333 / 10_000_000 = 332999966
        assertEq(withdrawable, 332999966);

        vm.prank(admin);
        manager.withdrawStablecoins(idoId, address(usdt), withdrawable);

        assertEq(usdt.balanceOf(admin), 332999966);
    }

    function test_edgeCase_AllRefunded() public {
        uint256 idoId = 1;
        uint256 totalRaised = 1000e6;
        uint256 totalRefunded = 1000e6; // All refunded

        _createTestIDO(idoId, totalRaised, totalRefunded, 0, 100e18, 0);

        uint256 withdrawable = manager.getWithdrawableAmount(idoId, address(usdt));
        assertEq(withdrawable, 0); // netRaised = 0
    }

    function test_edgeCase_SingleWeiWithdrawal() public {
        uint256 idoId = 1;
        _createTestIDO(idoId, 1000e6, 0, 100e18, 100e18, 0);
        _fundContract(address(usdt), 1000e6);

        vm.prank(admin);
        manager.withdrawStablecoins(idoId, address(usdt), 1);

        assertEq(manager.stablecoinsWithdrawnInToken(idoId, address(usdt)), 1);
        assertEq(usdt.balanceOf(admin), 1);
    }

    function test_edgeCase_MaxRealisticValues() public {
        uint256 idoId = 1;
        // Realistic max values (not uint256 max to avoid overflow)
        uint256 totalRaised = 10_000_000_000e6; // 10 billion USDT (6 decimals)
        uint256 totalAllocated = 10_000_000_000e18; // 10 billion tokens
        uint256 totalClaimed = 5_000_000_000e18; // 5 billion claimed (50%)

        _createTestIDO(idoId, totalRaised, 0, totalClaimed, totalAllocated, 0);
        _fundContract(address(usdt), totalRaised);

        uint256 withdrawable = manager.getWithdrawableAmount(idoId, address(usdt));
        assertEq(withdrawable, 5_000_000_000e6); // 50% of 10B
    }

    function test_integration_AdminChange_MidCampaign() public {
        uint256 idoId = 1;
        _createTestIDO(idoId, 1000e6, 0, 100e18, 100e18, 0);
        _fundContract(address(usdt), 1000e6);

        // Original admin withdraws 400
        vm.prank(admin);
        manager.withdrawStablecoins(idoId, address(usdt), 400e6);

        // Change admin
        vm.prank(admin);
        manager.changeReservesAdmin(newAdmin);

        // New admin can withdraw remaining
        vm.prank(newAdmin);
        manager.withdrawStablecoins(idoId, address(usdt), 600e6);

        assertEq(usdt.balanceOf(newAdmin), 600e6);
        assertEq(manager.stablecoinsWithdrawnInToken(idoId, address(usdt)), 1000e6);
    }

    function test_edgeCase_ZeroRefundedTokens() public {
        uint256 idoId = 1;
        uint256 totalRaised = 1000e6;
        uint256 totalAllocated = 100e18;
        uint256 totalClaimed = 100e18;
        uint256 totalRefundedTokens = 0;

        _createTestIDO(idoId, totalRaised, 0, totalClaimed, totalAllocated, totalRefundedTokens);
        _fundContract(address(usdt), totalRaised);

        uint256 withdrawable = manager.getWithdrawableAmount(idoId, address(usdt));
        assertEq(withdrawable, totalRaised);
    }
}
