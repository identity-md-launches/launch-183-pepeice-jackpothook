// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @notice Immutable Sepolia lottery for native/ERC20 v4 pools, backed entirely by ERC-6909 claims.
/// @dev Block-hash randomness is manipulable. A mainnet version needs Chainlink VRF.
contract JackpotHook is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for int256;
    using StateLibrary for IPoolManager;

    uint256 public constant POT_BPS = 100;
    uint256 public constant MIN_TICKET_FEE_ETH = 0.00001 ether;
    uint256 public constant MIN_TICKET_FEE_ICE = 1 ether;
    uint256 public constant ICE_PER_PEE = 10 ether;

    IPoolManager public immutable poolManager;

    struct Ticket {
        address player;
        Currency currency;
        uint256 fee;
        uint256 blockNumber;
        bool drawn;
    }

    struct Pot {
        uint256 eth;
        uint256 ice;
        Currency iceCurrency;
    }

    enum Action {
        Fund,
        Payout
    }

    struct Settlement {
        Action action;
        Currency iceCurrency;
        address player;
        uint256 eth;
        uint256 ice;
    }

    mapping(PoolId => Pot) private _pots;
    mapping(PoolId => mapping(uint256 => Ticket)) private _tickets;
    mapping(PoolId => uint256) public nextTicketId;

    error OnlyPoolManager();
    error InvalidPool();
    error PoolNotInitialized();
    error InvalidPees();
    error InvalidAmount();
    error PartialFill();
    error UnknownTicket();
    error AlreadyDrawn();
    error TooEarly();
    error UnexpectedCallback();
    error InexactFunding();

    event TicketIssued(
        PoolId indexed poolId,
        uint256 indexed ticketId,
        address indexed player,
        Currency currency,
        uint256 fee,
        uint256 blockNumber
    );
    /// @dev roll is zero for an expired ticket; otherwise it is in [1, 100].
    event Drawn(
        PoolId indexed poolId,
        uint256 indexed ticketId,
        address indexed player,
        uint256 roll,
        uint256 payoutEth,
        uint256 payoutIce
    );
    event TankFilled(PoolId indexed poolId, address indexed player, uint256 pees);

    constructor(IPoolManager manager) {
        if (address(manager) == address(0)) revert OnlyPoolManager();
        poolManager = manager;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory permissions) {
        permissions.beforeSwap = true;
        permissions.beforeSwapReturnDelta = true;
    }

    /// @notice Execute the trade atomically, collect exactly floor(abs(amountSpecified)/100), issue a ticket.
    /// @dev Self-initiated manager swaps skip this hook in v4. Executing the adjusted trade here lets
    /// us reject partial fills without enabling afterSwap. The outer swap is offset in full, and its
    /// returned deltas pass the real AMM result to the trader. All hook transient deltas net to zero.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        onlyPoolManager
        nonReentrant
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _validateKey(key);
        // Bound before negating, multiplying, or narrowing any signed amounts.
        int256 amount = params.amountSpecified;
        if (amount == 0 || amount > type(int128).max || amount < -int256(type(int128).max)) {
            revert InvalidAmount();
        }
        uint256 fee = uint256(amount < 0 ? -amount : amount) * POT_BPS / 10_000;
        bool specifiedIsEth = (amount < 0) == params.zeroForOne;
        BeforeSwapDelta delta = _executeSwap(key, params, fee, specifiedIsEth);

        PoolId id = key.toId();
        Pot storage pot = _pots[id];
        pot.iceCurrency = key.currency1;
        Currency currency = specifiedIsEth ? key.currency0 : key.currency1;
        if (specifiedIsEth) pot.eth += fee;
        else pot.ice += fee;

        if (fee >= (specifiedIsEth ? MIN_TICKET_FEE_ETH : MIN_TICKET_FEE_ICE)) {
            address player = hookData.length == 32 ? abi.decode(hookData, (address)) : tx.origin;
            uint256 ticketId = nextTicketId[id]++;
            _tickets[id][ticketId] = Ticket(player, currency, fee, block.number, false);
            emit TicketIssued(id, ticketId, player, currency, fee, block.number);
        }

        if (fee != 0) poolManager.mint(address(this), currency.toId(), fee);
        return (this.beforeSwap.selector, delta, 0);
    }

    function _executeSwap(PoolKey calldata key, SwapParams calldata params, uint256 fee, bool specifiedIsEth)
        private
        returns (BeforeSwapDelta)
    {
        // fee <= uint128(int128.max) / 100, established by beforeSwap's amount bound.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 adjusted = params.amountSpecified + int256(fee);
        if (adjusted > type(int128).max) revert InvalidAmount();
        BalanceDelta actual =
            poolManager.swap(key, SwapParams(params.zeroForOne, adjusted, params.sqrtPriceLimitX96), bytes(""));
        int128 specified = specifiedIsEth ? actual.amount0() : actual.amount1();
        if (int256(specified) != adjusted) revert PartialFill();
        int128 unspecified = specifiedIsEth ? actual.amount1() : actual.amount0();
        return toBeforeSwapDelta((-params.amountSpecified).toInt128(), (-int256(unspecified)).toInt128());
    }

    /// @notice Resolve a ticket once. Anyone may trigger payment, always to its recorded player.
    /// @dev For a ticket in block B, draws are allowed in B+2 ... B+256, and expire at B+257.
    function draw(PoolId id, uint256 ticketId) external nonReentrant {
        if (ticketId >= nextTicketId[id]) revert UnknownTicket();
        Ticket storage entry = _tickets[id][ticketId];
        if (entry.drawn) revert AlreadyDrawn();
        if (block.number <= entry.blockNumber + 1) revert TooEarly();
        entry.drawn = true;

        uint256 roll;
        uint256 payoutEth;
        uint256 payoutIce;
        Pot storage pot = _pots[id];
        if (block.number - entry.blockNumber <= 256) {
            roll = uint256(keccak256(abi.encode(blockhash(entry.blockNumber + 1), id, ticketId))) % 100 + 1;
            if (roll == 77) {
                // Quotient/remainder form avoids overflow while preserving floor(pot * 90 / 100).
                payoutEth = _ninetyPercent(pot.eth);
                payoutIce = _ninetyPercent(pot.ice);
            } else if (roll % 20 == 0) {
                uint256 reward = entry.fee * 20;
                bool isEth = entry.currency.isAddressZero();
                uint256 cap = (isEth ? pot.eth : pot.ice) / 10;
                if (reward > cap) reward = cap;
                if (isEth) payoutEth = reward;
                else payoutIce = reward;
            }
        }

        pot.eth -= payoutEth;
        pot.ice -= payoutIce;
        emit Drawn(id, ticketId, entry.player, roll, payoutEth, payoutIce);
        if (payoutEth != 0 || payoutIce != 0) {
            poolManager.unlock(
                abi.encode(Settlement(Action.Payout, pot.iceCurrency, entry.player, payoutEth, payoutIce))
            );
        }
    }

    /// @notice Buy 1 ... 1000 local pees by adding exactly 10 ICE each to the pool's claims.
    /// @dev Approve this hook for the ICE amount first. No ticket or on-chain pee balance is created.
    function fillTank(PoolKey calldata key, uint256 pees) external nonReentrant {
        _validateKey(key);
        if (pees == 0 || pees > 1000) revert InvalidPees();
        PoolId id = key.toId();
        (uint160 price,,,) = poolManager.getSlot0(id);
        if (price == 0) revert PoolNotInitialized();
        uint256 amount = pees * ICE_PER_PEE;
        Pot storage pot = _pots[id];
        pot.iceCurrency = key.currency1;
        pot.ice += amount;
        emit TankFilled(id, msg.sender, pees);
        poolManager.unlock(abi.encode(Settlement(Action.Fund, key.currency1, msg.sender, 0, amount)));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        if (!_reentrancyGuardEntered()) revert UnexpectedCallback();
        Settlement memory settlement = abi.decode(data, (Settlement));
        if (settlement.action == Action.Fund) {
            poolManager.sync(settlement.iceCurrency);
            IERC20(Currency.unwrap(settlement.iceCurrency))
                .safeTransferFrom(settlement.player, address(poolManager), settlement.ice);
            if (poolManager.settle() != settlement.ice) revert InexactFunding();
            poolManager.mint(address(this), settlement.iceCurrency.toId(), settlement.ice);
        } else {
            _pay(Currency.wrap(address(0)), settlement.player, settlement.eth);
            _pay(settlement.iceCurrency, settlement.player, settlement.ice);
        }
        return bytes("");
    }

    function pots(PoolId id) external view returns (uint256 eth, uint256 ice) {
        Pot storage pot = _pots[id];
        return (pot.eth, pot.ice);
    }

    function ticket(PoolId id, uint256 ticketId) external view returns (Ticket memory) {
        if (ticketId >= nextTicketId[id]) revert UnknownTicket();
        return _tickets[id][ticketId];
    }

    function _pay(Currency currency, address player, uint256 amount) private {
        if (amount == 0) return;
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, player, amount);
    }

    function _validateKey(PoolKey calldata key) private view {
        if (address(key.hooks) != address(this) || !key.currency0.isAddressZero() || key.currency1.isAddressZero()) {
            revert InvalidPool();
        }
    }

    function _ninetyPercent(uint256 amount) private pure returns (uint256) {
        // The remainder term restores precision lost by the first division.
        // forge-lint: disable-next-line(divide-before-multiply)
        return (amount / 10) * 9 + (amount % 10) * 9 / 10;
    }
}
