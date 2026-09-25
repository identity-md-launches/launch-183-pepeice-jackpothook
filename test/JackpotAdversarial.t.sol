// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {JackpotFixture, JackpotHook, PoolKey, PoolId, Currency, IHooks} from "./fixtures/JackpotFixture.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract PayoutReceiver {
    JackpotHook internal immutable hook;
    PoolKey internal key;
    bool public reject = true;
    bool public attempted;
    bool public repeatSucceeded;
    bool public otherDrawSucceeded;
    bool public tankSucceeded;

    constructor(JackpotHook hook_, PoolKey memory key_) {
        hook = hook_;
        key = key_;
    }

    function accept() external {
        reject = false;
    }

    receive() external payable {
        require(!reject, "reject ETH");
        attempted = true;
        (repeatSucceeded,) = address(hook).call(abi.encodeCall(hook.draw, (key.toId(), 0)));
        (otherDrawSucceeded,) = address(hook).call(abi.encodeCall(hook.draw, (key.toId(), 1)));
        (tankSucceeded,) = address(hook).call(abi.encodeCall(hook.fillTank, (key, 1)));
    }
}

contract TaxToken is ERC20 {
    constructor() ERC20("Unsupported token", "TAX") {
        _mint(msg.sender, 1000 ether);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0)) {
            super._update(from, address(0), amount / 10);
            amount -= amount / 10;
        }
        super._update(from, to, amount);
    }
}

contract JackpotAdversarialTest is JackpotFixture {
    function test_failedPaymentRollsBackAndRetryRejectsReentrancy() public {
        PayoutReceiver receiver = new PayoutReceiver(hook, key);
        _swap(true, -int256(1 ether), abi.encode(receiver));
        _swap(false, -int256(1000 ether), abi.encode(receiver));
        _forceRoll(0, 77);
        (uint256 ethPot, uint256 icePot) = hook.pots(poolId);
        vm.expectRevert();
        hook.draw(poolId, 0);
        assertFalse(hook.ticket(poolId, 0).drawn);
        assertEq(address(receiver).balance, 0);
        assertEq(ice.balanceOf(address(receiver)), 0);
        (uint256 ethAfterFailure, uint256 iceAfterFailure) = hook.pots(poolId);
        assertEq(ethAfterFailure, ethPot);
        assertEq(iceAfterFailure, icePot);
        _assertBacking();

        receiver.accept();
        hook.draw(poolId, 0);
        assertTrue(receiver.attempted());
        assertFalse(receiver.repeatSucceeded());
        assertFalse(receiver.otherDrawSucceeded());
        assertFalse(receiver.tankSucceeded());
        assertTrue(hook.ticket(poolId, 0).drawn);
        assertFalse(hook.ticket(poolId, 1).drawn);
        assertEq(address(receiver).balance, ethPot * 9 / 10);
        assertEq(ice.balanceOf(address(receiver)), icePot * 9 / 10);
        _assertBacking();
    }

    function test_tankRejectsFeeOnTransferWithoutCreatingUnbackedPot() public {
        TaxToken taxed = new TaxToken();
        PoolKey memory other = key;
        other.currency1 = Currency.wrap(address(taxed));
        manager.initialize(other, INITIAL_PRICE);
        taxed.approve(address(hook), type(uint256).max);
        uint256 before = taxed.balanceOf(address(this));
        vm.expectRevert(JackpotHook.InexactFunding.selector);
        hook.fillTank(other, 1);
        (uint256 ethPot, uint256 icePot) = hook.pots(other.toId());
        assertEq(ethPot + icePot, 0);
        assertEq(taxed.balanceOf(address(this)), before);
        assertEq(manager.balanceOf(address(hook), uint160(address(taxed))), 0);
    }

    function test_poolPotsAndTicketSequencesAreIsolatedWithSharedCurrencies() public {
        PoolKey memory first = key;
        PoolId firstId = poolId;
        _seed();
        (uint256 firstEth, uint256 firstIce) = hook.pots(firstId);

        key.fee = 500;
        poolId = key.toId();
        manager.initialize(key, INITIAL_PRICE);
        liquidity.modifyLiquidity{value: 200 ether}(key, ModifyLiquidityParams(-887220, 887220, 100_000 ether, 0), "");
        assertEq(hook.nextTicketId(poolId), 0);
        _swap(true, -int256(0.1 ether), abi.encode(PLAYER));
        _fill(10);
        (uint256 secondEth, uint256 secondIce) = hook.pots(poolId);
        _forceRoll(0, 77);
        hook.draw(poolId, 0);
        assertEq(PLAYER.balance, secondEth * 9 / 10);
        assertEq(ice.balanceOf(PLAYER), secondIce * 9 / 10);
        (uint256 firstEthAfter, uint256 firstIceAfter) = hook.pots(firstId);
        assertEq(firstEthAfter, firstEth);
        assertEq(firstIceAfter, firstIce);
        assertFalse(hook.ticket(firstId, 0).drawn);
        assertEq(hook.nextTicketId(firstId), 2);
        assertEq(hook.nextTicketId(poolId), 1);
        (secondEth, secondIce) = hook.pots(poolId);
        assertEq(manager.balanceOf(address(hook), 0), firstEth + secondEth);
        assertEq(manager.balanceOf(address(hook), uint160(address(ice))), firstIce + secondIce);
        key = first;
        poolId = firstId;
    }

    function test_initialOneSidedLiquidityFirstBuyFirstSellAndUnwind() public {
        // A position below the initial price is entirely ICE, as in a one-sided launch.
        key.fee = 500;
        poolId = key.toId();
        uint160 boundary = TickMath.getSqrtPriceAtTick(138180);
        manager.initialize(key, boundary);
        uint256 nativeBefore = address(this).balance;
        liquidity.modifyLiquidity(key, ModifyLiquidityParams(137580, 138180, 100_000 ether, 0), "");
        assertEq(address(this).balance, nativeBefore);
        uint256 traderIce = ice.balanceOf(TRADER);
        vm.prank(TRADER);
        assertTrue(ice.transfer(address(this), traderIce));
        assertEq(ice.balanceOf(TRADER), 0);
        _swap(true, -int256(0.01 ether), abi.encode(PLAYER));
        assertGt(ice.balanceOf(TRADER), 1000 ether);
        _swap(false, -int256(1000 ether), abi.encode(PLAYER));
        liquidity.modifyLiquidity(key, ModifyLiquidityParams(137580, 138180, -int256(100_000 ether), 0), "");
        _assertBacking();
    }
}
