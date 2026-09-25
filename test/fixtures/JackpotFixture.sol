// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PepeIce} from "../../src/PepeIce.sol";
import {JackpotHook} from "../../src/JackpotHook.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

abstract contract JackpotFixture is Test {
    uint160 internal constant FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
    uint160 internal constant INITIAL_PRICE = 79228162514264337593543950336000;
    address internal constant TRADER = address(0xA11CE);
    address internal constant PLAYER = address(0xBEEF);
    address internal constant ORIGIN = address(0xCAFE);

    PepeIce internal ice;
    PoolManager internal manager;
    JackpotHook internal hook;
    PoolSwapTest internal router;
    PoolModifyLiquidityTest internal liquidity;
    PoolKey internal key;
    PoolId internal poolId;

    event TicketIssued(
        PoolId indexed poolId,
        uint256 indexed ticketId,
        address indexed player,
        Currency currency,
        uint256 fee,
        uint256 blockNumber
    );
    event Drawn(
        PoolId indexed poolId,
        uint256 indexed ticketId,
        address indexed player,
        uint256 roll,
        uint256 payoutEth,
        uint256 payoutIce
    );
    event TankFilled(PoolId indexed poolId, address indexed player, uint256 pees);

    function setUp() public virtual {
        vm.roll(100);
        vm.deal(address(this), 1_000_000 ether);
        vm.deal(TRADER, 1_000_000 ether);
        ice = new PepeIce();
        manager = new PoolManager(address(this));
        bytes32 hash = keccak256(abi.encodePacked(type(JackpotHook).creationCode, abi.encode(manager)));
        for (uint256 i;; ++i) {
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), hash)))));
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK != FLAGS) continue;
            hook = new JackpotHook{salt: bytes32(i)}(manager);
            break;
        }
        router = new PoolSwapTest(manager);
        liquidity = new PoolModifyLiquidityTest(manager);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(ice)), 3000, 60, IHooks(address(hook)));
        poolId = key.toId();
        // No pad identity or beforeInitialize callback is needed.
        vm.prank(address(0xFAc7));
        manager.initialize(key, INITIAL_PRICE);
        ice.approve(address(liquidity), type(uint256).max);
        liquidity.modifyLiquidity{value: 200 ether}(key, ModifyLiquidityParams(-887220, 887220, 100_000 ether, 0), "");
        assertTrue(ice.transfer(TRADER, 10_000_000 ether));
        vm.startPrank(TRADER);
        ice.approve(address(router), type(uint256).max);
        ice.approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    function _swap(bool zeroForOne, int256 amount, bytes memory data) internal returns (BalanceDelta) {
        vm.prank(TRADER, ORIGIN);
        return router.swap{value: zeroForOne ? 20 ether : 0}(
            key,
            SwapParams(zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            data
        );
    }

    function _fill(uint256 pees) internal {
        vm.prank(TRADER);
        hook.fillTank(key, pees);
    }

    function _seed() internal {
        _swap(true, -int256(1 ether), abi.encode(PLAYER));
        _swap(false, -int256(1000 ether), abi.encode(PLAYER));
    }

    // Force only the future block hash; never replace the production draw implementation.
    function _forceRoll(uint256 ticketId, uint256 roll) internal {
        JackpotHook.Ticket memory entry = hook.ticket(poolId, ticketId);
        vm.roll(entry.blockNumber + 2);
        vm.setBlockhash(entry.blockNumber + 1, _hashForRoll(poolId, ticketId, roll));
    }

    function _hashForRoll(PoolId id, uint256 ticketId, uint256 roll) internal pure returns (bytes32) {
        for (uint256 i = 1;; ++i) {
            bytes32 candidate = bytes32(i);
            if (uint256(keccak256(abi.encode(candidate, id, ticketId))) % 100 + 1 == roll) return candidate;
        }
        revert();
    }

    function _assertBacking() internal view {
        (uint256 ethPot, uint256 icePot) = hook.pots(poolId);
        assertEq(manager.balanceOf(address(hook), 0), ethPot);
        assertEq(manager.balanceOf(address(hook), uint160(address(ice))), icePot);
        assertEq(address(hook).balance, 0);
        assertEq(ice.balanceOf(address(hook)), 0);
    }

    function _expectHookError(bytes4 selector) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                hook.beforeSwap.selector,
                abi.encodeWithSelector(selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    receive() external payable {}
}
