// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    JackpotFixture,
    JackpotHook,
    Hooks,
    IHooks,
    Currency,
    PoolKey,
    PoolId,
    BalanceDelta,
    SwapParams,
    PoolSwapTest,
    TickMath
} from "./fixtures/JackpotFixture.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

contract JackpotHookTest is JackpotFixture {
    using StateLibrary for IPoolManager;

    function test_factoryInitializationAndPermissions() public view {
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(poolId);
        assertEq(price, INITIAL_PRICE);
        assertEq(address(hook.poolManager()), address(manager));
        Hooks.Permissions memory expected;
        expected.beforeSwap = true;
        expected.beforeSwapReturnDelta = true;
        assertEq(abi.encode(hook.getHookPermissions()), abi.encode(expected));
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, FLAGS);
    }

    function test_constructorRejectsWrongAddressFlags() public {
        bytes32 hash = keccak256(abi.encodePacked(type(JackpotHook).creationCode, abi.encode(manager)));
        bytes32 salt = keccak256("invalid flags");
        address predicted =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hash)))));
        assertTrue(uint160(predicted) & Hooks.ALL_HOOK_MASK != FLAGS);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new JackpotHook{salt: salt}(manager);
    }

    function test_callbacksRejectUntrustedCallers() public {
        vm.expectRevert(JackpotHook.OnlyPoolManager.selector);
        hook.beforeSwap(TRADER, key, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1), "");
        vm.expectRevert(JackpotHook.OnlyPoolManager.selector);
        hook.unlockCallback("");
        vm.expectRevert(JackpotHook.UnexpectedCallback.selector);
        vm.prank(address(manager));
        hook.unlockCallback("");
    }

    function test_allFourSwapModesHaveExactAccounting() public {
        _checkSwap(true, -int256(0.1 ether));
        _checkSwap(false, -int256(1000 ether));
        _checkSwap(true, int256(1000 ether));
        _checkSwap(false, int256(0.1 ether));
    }

    function testFuzz_swapExactAmountsAndFeeRounding(bool zeroForOne, bool exactIn, uint96 raw) public {
        bool ethSpecified = exactIn == zeroForOne;
        uint256 amount = bound(raw, ethSpecified ? 1000 : 1e12, ethSpecified ? 0.1 ether : 1000 ether);
        // amount is at most 1000 ether, far below int256.max.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 signedAmount = int256(amount);
        _checkSwap(zeroForOne, exactIn ? -signedAmount : signedAmount);
    }

    function _checkSwap(bool zeroForOne, int256 amount) internal {
        bool ethSpecified = (amount < 0) == zeroForOne;
        uint256 magnitude = uint256(amount < 0 ? -amount : amount);
        (uint256 ethBefore, uint256 iceBefore) = hook.pots(poolId);
        uint256 traderBefore = ethSpecified ? TRADER.balance : ice.balanceOf(TRADER);
        BalanceDelta delta = _swap(zeroForOne, amount, abi.encode(PLAYER));
        assertEq(int256(ethSpecified ? delta.amount0() : delta.amount1()), amount);
        uint256 traderAfter = ethSpecified ? TRADER.balance : ice.balanceOf(TRADER);
        assertEq(traderAfter, amount < 0 ? traderBefore - magnitude : traderBefore + magnitude);
        (uint256 ethAfter, uint256 iceAfter) = hook.pots(poolId);
        assertEq(ethAfter - ethBefore, ethSpecified ? magnitude / 100 : 0);
        assertEq(iceAfter - iceBefore, ethSpecified ? 0 : magnitude / 100);
        _assertBacking();
    }

    function test_partialFillsRevertInEveryModeAndRollBackFees() public {
        for (uint256 i; i < 4; ++i) {
            bool zeroForOne = i < 2;
            bool exactIn = i % 2 == 0;
            bool ethSpecified = zeroForOne == exactIn;
            int256 amount = ethSpecified ? int256(0.1 ether) : int256(1000 ether);
            uint160 limit = zeroForOne ? INITIAL_PRICE - 1 : INITIAL_PRICE + 1;
            _expectHookError(JackpotHook.PartialFill.selector);
            vm.prank(TRADER, ORIGIN);
            router.swap{value: zeroForOne ? 1 ether : 0}(
                key,
                SwapParams(zeroForOne, exactIn ? -amount : amount, limit),
                PoolSwapTest.TestSettings(false, false),
                abi.encode(PLAYER)
            );
            assertEq(hook.nextTicketId(poolId), 0);
            _assertBacking();
            (uint256 ethPot, uint256 icePot) = hook.pots(poolId);
            assertEq(ethPot + icePot, 0);
        }
    }

    function test_emptyPoolCannotCollectFeeOrIssueTicket() public {
        liquidity.modifyLiquidity(key, ModifyLiquidityParams(-887220, 887220, -int256(100_000 ether), 0), "");
        _expectHookError(JackpotHook.PartialFill.selector);
        _swap(true, -int256(1 ether), abi.encode(PLAYER));
        assertEq(hook.nextTicketId(poolId), 0);
        _assertBacking();
    }

    function test_ticketAttributionAndThresholds() public {
        vm.expectEmit(true, true, true, true, address(hook));
        emit TicketIssued(poolId, 0, PLAYER, key.currency0, 0.00001 ether, block.number);
        _swap(true, -int256(0.001 ether), abi.encode(PLAYER));
        JackpotHook.Ticket memory entry = hook.ticket(poolId, 0);
        assertEq(entry.player, PLAYER);
        assertEq(Currency.unwrap(entry.currency), address(0));
        assertEq(entry.fee, 0.00001 ether);
        assertEq(entry.blockNumber, block.number);
        assertFalse(entry.drawn);

        _swap(false, -int256(100 ether), "");
        assertEq(hook.ticket(poolId, 1).player, ORIGIN);
        assertEq(hook.ticket(poolId, 1).fee, 1 ether);
        _swap(false, -int256(100 ether), hex"1234");
        assertEq(hook.ticket(poolId, 2).player, ORIGIN);
        _swap(true, -int256(0.001 ether - 1), abi.encode(PLAYER));
        _swap(false, -int256(100 ether - 1), abi.encode(PLAYER));
        assertEq(hook.nextTicketId(poolId), 3);
        _assertBacking();
    }

    function test_smallAndZeroFeeSwapsDoNotIssueTickets() public {
        _checkSwap(true, -int256(99));
        _checkSwap(true, -int256(100));
        assertEq(hook.nextTicketId(poolId), 0);
        (uint256 ethPot,) = hook.pots(poolId);
        assertEq(ethPot, 1);
    }

    function test_extremeAmountsRevertWithoutAccountingChanges() public {
        _expectHookError(JackpotHook.InvalidAmount.selector);
        _swap(true, type(int256).min, "");
        _expectHookError(JackpotHook.InvalidAmount.selector);
        _swap(true, type(int256).max, "");
        _expectHookError(JackpotHook.InvalidAmount.selector);
        _swap(true, int256(type(int128).max), "");
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        _swap(true, 0, "");
        _assertBacking();
    }

    function test_drawTooEarlyAndMissingTickets() public {
        vm.expectRevert(JackpotHook.UnknownTicket.selector);
        hook.draw(poolId, 0);
        vm.expectRevert(JackpotHook.UnknownTicket.selector);
        hook.ticket(poolId, 0);
        _seed();
        vm.expectRevert(JackpotHook.TooEarly.selector);
        hook.draw(poolId, 0);
        vm.roll(block.number + 1);
        vm.expectRevert(JackpotHook.TooEarly.selector);
        hook.draw(poolId, 0);
        assertFalse(hook.ticket(poolId, 0).drawn);
    }

    function test_jackpotPaysBothPotsToRecordedPlayerOnce() public {
        _seed();
        // Non-multiple-of-ten pot balances exercise percentage rounding.
        _swap(true, -int256(1234), abi.encode(PLAYER));
        _swap(false, -int256(1e12 + 1234), abi.encode(PLAYER));
        _fill(100);
        (uint256 ethPot, uint256 icePot) = hook.pots(poolId);
        _forceRoll(0, 77);
        vm.expectEmit(true, true, true, true, address(hook));
        emit Drawn(poolId, 0, PLAYER, 77, ethPot * 9 / 10, icePot * 9 / 10);
        vm.prank(address(0xBAD));
        hook.draw(poolId, 0);
        assertEq(PLAYER.balance, ethPot * 9 / 10);
        assertEq(ice.balanceOf(PLAYER), icePot * 9 / 10);
        (uint256 ethLeft, uint256 iceLeft) = hook.pots(poolId);
        assertEq(ethLeft, ethPot - ethPot * 9 / 10);
        assertEq(iceLeft, icePot - icePot * 9 / 10);
        assertTrue(hook.ticket(poolId, 0).drawn);
        vm.expectRevert(JackpotHook.AlreadyDrawn.selector);
        hook.draw(poolId, 0);
        _assertBacking();
    }

    function test_expiryIsBasedOnTicketBlock() public {
        _seed();
        _forceRoll(0, 77);
        vm.roll(hook.ticket(poolId, 0).blockNumber + 257);
        (uint256 ethPot, uint256 icePot) = hook.pots(poolId);
        vm.expectEmit(true, true, true, true, address(hook));
        emit Drawn(poolId, 0, PLAYER, 0, 0, 0);
        hook.draw(poolId, 0);
        assertEq(PLAYER.balance, 0);
        assertEq(ice.balanceOf(PLAYER), 0);
        (uint256 ethLeft, uint256 iceLeft) = hook.pots(poolId);
        assertEq(ethLeft, ethPot);
        assertEq(iceLeft, icePot);
        vm.expectRevert(JackpotHook.AlreadyDrawn.selector);
        hook.draw(poolId, 0);
        _assertBacking();
    }

    function test_drawAtAge256StillUsesFutureHash() public {
        _seed();
        _forceRoll(0, 77);
        vm.roll(hook.ticket(poolId, 0).blockNumber + 256);
        hook.draw(poolId, 0);
        assertGt(PLAYER.balance, 0);
        _assertBacking();
    }

    function test_allGoldenRollsPayCappedEth() public {
        _seed();
        for (uint256 roll = 20; roll <= 100; roll += 20) {
            uint256 id = hook.nextTicketId(poolId);
            _swap(true, -int256(0.001 ether), abi.encode(PLAYER));
            _forceRoll(id, roll);
            (uint256 ethPot, uint256 icePot) = hook.pots(poolId);
            uint256 reward = hook.ticket(poolId, id).fee * 20;
            if (reward > ethPot / 10) reward = ethPot / 10;
            uint256 before = PLAYER.balance;
            hook.draw(poolId, id);
            assertEq(PLAYER.balance - before, reward);
            (uint256 ethLeft, uint256 iceLeft) = hook.pots(poolId);
            assertEq(ethLeft, ethPot - reward);
            assertEq(iceLeft, icePot);
            _assertBacking();
        }
    }

    function test_goldenFlushCapsAtTenPercent() public {
        _seed();
        (uint256 ethPot, uint256 icePot) = hook.pots(poolId);
        _forceRoll(0, 20);
        hook.draw(poolId, 0);
        assertEq(PLAYER.balance, ethPot / 10);
        assertEq(ice.balanceOf(PLAYER), 0);
        _forceRoll(1, 100);
        hook.draw(poolId, 1);
        assertEq(ice.balanceOf(PLAYER), icePot / 10);
        _assertBacking();
    }

    function test_goldenFlushUncappedTwentyTimesIceFee() public {
        _swap(false, -int256(100 ether), abi.encode(PLAYER));
        _fill(1000);
        _forceRoll(0, 40);
        hook.draw(poolId, 0);
        assertEq(ice.balanceOf(PLAYER), 20 ether);
        assertEq(PLAYER.balance, 0);
        _assertBacking();
    }

    function test_losingRollPaysNothingAndCannotBeDrawnAgain() public {
        _seed();
        _forceRoll(0, 1);
        hook.draw(poolId, 0);
        assertEq(PLAYER.balance, 0);
        assertEq(ice.balanceOf(PLAYER), 0);
        vm.expectRevert(JackpotHook.AlreadyDrawn.selector);
        hook.draw(poolId, 0);
        _assertBacking();
    }

    function test_fillTankSettlesExactClaimsAndEmitsPurchase() public {
        uint256 before = ice.balanceOf(TRADER);
        vm.expectEmit(true, true, false, true, address(hook));
        emit TankFilled(poolId, TRADER, 1000);
        _fill(1000);
        _fill(1);
        assertEq(before - ice.balanceOf(TRADER), 10010 ether);
        (uint256 ethPot, uint256 icePot) = hook.pots(poolId);
        assertEq(ethPot, 0);
        assertEq(icePot, 10010 ether);
        assertEq(hook.nextTicketId(poolId), 0);
        _assertBacking();
    }

    function test_fillTankRejectsInvalidInputsAndMissingApproval() public {
        vm.expectRevert(JackpotHook.InvalidPees.selector);
        _fill(0);
        vm.expectRevert(JackpotHook.InvalidPees.selector);
        _fill(1001);
        PoolKey memory wrong = key;
        wrong.hooks = IHooks(address(0));
        vm.expectRevert(JackpotHook.InvalidPool.selector);
        hook.fillTank(wrong, 1);
        wrong = key;
        wrong.currency0 = key.currency1;
        vm.expectRevert(JackpotHook.InvalidPool.selector);
        hook.fillTank(wrong, 1);
        wrong = key;
        wrong.fee = 500;
        vm.expectRevert(JackpotHook.PoolNotInitialized.selector);
        hook.fillTank(wrong, 1);
        vm.prank(TRADER);
        ice.approve(address(hook), 0);
        vm.expectRevert();
        _fill(1);
        _assertBacking();
    }
}
