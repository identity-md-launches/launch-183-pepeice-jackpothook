# On-chain release: specification

This is the contract and site specification for the Sepolia release of *pepes armed with ai*.
`prototype/index.html` is the reference for look, feel and game flow; this file is the reference
for everything that touches the chain. Where the two differ, this file wins.

Chain: Sepolia only (chainId 11155111). No mainnet deployment is part of this release.

## 1. What the prototype simulates today

| Prototype feature | Where in `prototype/index.html` | Simulated how |
|---|---|---|
| $ICE balance | `showBalance`, `balance` | a number in the page |
| Pee costs 10 $ICE | `PEE_COST` | subtracted locally |
| Jackpot swap: 100 $ICE to $IMD, 1% of each swap to the jackpot, roll 1-100, a 77 wins | `JS`, `jackpotSwap`, `quoteSwap` | `Math.random`, baked prices |
| Golden throne: ETH to $IMD, 2% fee, 1 in 20 "golden flush" pays +20%, grants 5 free climb bursts | `TH`, `thBuy` | demo wallet of 0.05 ETH, `Math.random` |
| Pizza climb: burns $ICE per thrust, tiered prizes | `CL`, `CTIERS` | local |

## 2. What goes on chain

One IMD `univ4_hook` launch: the launch token, one hook, and the pool the network's factory opens
for them.

- **$ICE on Sepolia is the launch token.** It is a test token for this game and is unrelated to
  any mainnet token with the same symbol.
- **There is no $IMD on Sepolia.** Everywhere the prototype shows $IMD, the release uses Sepolia
  ETH, which is the other side of the pool.
- **Pees, the tank and the climb stay playable in the browser.** Only value moves on chain:
  swaps, the jackpot, tank purchases and payouts.

### 2.1 Token: `PepeIce`

- OpenZeppelin ERC-20, name `pepes ice`, symbol `ICE`, 18 decimals.
- Zero-argument constructor that mints the fixed supply of exactly 10^27 minor units
  (1,000,000,000 ICE) to `msg.sender`. Nothing else.
- No mint function, no owner, no pause, no proxy. `ERC20Burnable` is allowed.
- Supply and allocation splits are **not** written in `launch.json`; they come from the network's
  versioned launch policy, and the factory must receive the full 10^27 after deployment.

### 2.2 Hook: `JackpotHook`

Constructor takes exactly one argument, `IPoolManager poolManager`. In `launch.json` it is the
literal Sepolia PoolManager address `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`
(no `$placeholders`). No owner, no admin, no fee setter, no pause, no upgrade path,
no `selfdestruct`, no `delegatecall`.

Permissions: `beforeSwap` and `beforeSwapReturnDelta` only. **Never `beforeInitialize`**, because
the factory opens the pool. The constructor calls `Hooks.validateHookPermissions`, and the
deployer mines the CREATE2 salt for the declared bits.

The published release `identity-md-launches/launch-124-workflow-contract-stage-context`
(`BurnShareHook`, 1% of every swap burned) is the proven pattern for the fee path. This hook keeps
the 1% instead of burning it.

**Fee to the pot.** On every swap, `beforeSwap` takes `|amountSpecified| * 100 / 10000` (1%,
rounded down, compile-time constant `POT_BPS = 100`) of the specified currency and credits it to
that pool's pot in that currency. The pot is held as ERC-6909 claims on the PoolManager, so
nothing needs to be released mid-swap. The trader pays or receives exactly `amountSpecified`, as
in the burn hook. A pool therefore has two pots, one in ETH and one in ICE.

**Tickets.** Every swap whose fee is at least `MIN_TICKET_FEE` in its currency (0.00001 ETH or
1 ICE, whichever currency paid it) creates a ticket:

- ticket id, sequential per pool
- player: the address ABI-encoded in `hookData` when `hookData.length == 32`; otherwise
  `tx.origin`. `hookData` only chooses who receives the ticket the swapper paid for, so
  nothing can be stolen through it.
- currency and fee paid
- block number

It emits `TicketIssued(poolId, ticketId, player, currency, fee, blockNumber)`.

**Draw.** `draw(PoolId, uint256 ticketId)` can be called by anyone. It resolves the ticket once,
using the hash of the block after the ticket's block:

- The draw reverts until that block exists.
- A ticket older than 256 blocks expires and pays nothing.
- `roll = uint256(keccak256(abi.encode(blockhash(ticketBlock + 1), poolId, ticketId))) % 100 + 1`
- **roll == 77, the jackpot.** The ticket's player receives 90% of both pots (ETH and ICE); 10%
  of each stays as the next seed.
- **roll is 20, 40, 60, 80 or 100, the golden flush (1 in 20).** The player receives 20 times the
  fee the ticket paid (20% of the swap amount), in the ticket's currency, capped at 10% of that
  pot.
- **Any other roll** pays nothing.

Each draw emits `Drawn(poolId, ticketId, player, roll, payoutEth, payoutIce)`. Payouts go
through `poolManager.unlock`: burn the claims and `take` to the player. Checks-effects-interactions
throughout, and a ticket can never be drawn twice.

Rolls come from a future block hash. On Sepolia that is fair enough for a game. `docs/SECURITY.md`
must state that a block proposer can influence it, and that a mainnet version needs Chainlink VRF
instead.

**Tank.** `fillTank(PoolKey calldata key, uint256 pees)` transfers `pees * 10 ICE` from the caller
into that pool's ICE pot (ERC-20 `transferFrom` to the hook, then settle into claims, or hold as
ERC-20; either is fine if the accounting is exact). It emits `TankFilled(poolId, player, pees)`.

- `key.hooks` must be this hook, and the ICE side is the non-native currency of `key`.
- `1 <= pees <= 1000`.
- The site lets the player pee as many times as they have bought. Pees themselves are local.

**Views.** `pots(PoolId) returns (uint256 eth, uint256 ice)`, `ticket(PoolId, uint256)` and
`nextTicketId(PoolId)`.

### 2.3 Pool

- `pairedCurrency` native ETH (`0x000...000`), so currency0 = ETH and currency1 = ICE.
- Fee 3000, tickSpacing 60.
- `initialPrice` = 1,000,000 ICE per ETH (sqrtPriceX96 `79228162514264337593543950336000`),
  the same as the burn-hook release.

### 2.4 Out of scope for this release

- **Climb prizes stay local points.** A skill result cannot be proved on chain without a trusted
  server.
- **No mainnet deployment and no bridge to mainnet $ICE or $IMD.**

## 3. Tests the contracts must pass

`forge build` and `forge test`, including:

1. The factory-shaped `PoolManager.initialize` from a non-pad sender succeeds with this hook.
2. A swap in each direction, exact-in and exact-out: the trader pays or receives exactly
   `amountSpecified`, and the right pot grows by exactly 1%.
3. **Ticket attribution:** with 32-byte `hookData` the ticket goes to the decoded player; without
   it the ticket goes to `tx.origin`.
4. **Draw results:**
   - A draw in the same block reverts.
   - A draw after 256 blocks pays nothing.
   - A forced 77 pays 90% of both pots.
   - A forced golden flush pays 20 times the fee, capped at 10% of the pot.
   - No ticket can be drawn twice.
5. **`fillTank`:**
   - it moves exactly `pees * 10 ICE` into the pot
   - it rejects 0 and anything over 1000
   - it rejects a pool key that belongs to another hook
6. Fuzz: no sequence of swaps, tank fills and draws can pay out more than the pots hold.

## 4. The site

Build it from `prototype/index.html`. Keep the art, animation, music (`prototype/assets/bgm.mp3`)
and controls as they are. Replace only the simulated parts:

| Prototype | Release |
|---|---|
| $ICE balance | the connected wallet's ICE balance |
| $IMD balance and prices | the wallet's Sepolia ETH, and the pool's live price |
| Jackpot swap, 100 ICE to $IMD | a real swap of 100 ICE for ETH through the pool (or the ETH amount the flip direction chooses), passing the player's address as `hookData` |
| The dice roll | after the next block, read the ticket and compute the roll the contract will compute. When it wins, call `draw`; otherwise just show the roll |
| Jackpot marquee | `pots(poolId)`, both currencies |
| Golden throne, ETH to $IMD | a real ETH to ICE swap of 0.001, 0.005 or 0.01 ETH, with the same ticket and draw. The golden bladder (5 free climb bursts) is granted locally after a confirmed swap |
| Pee costs 10 $ICE | "fill the tank" calls `fillTank`; pees count down locally from the tank |

Technical requirements:

- **Stack:** Vite, React, TypeScript, RainbowKit, wagmi and viem. Source under `web/`, and a
  relative-base static export to `dist/`. The game's own DOM and animation code can stay plain
  JavaScript inside the React shell.
- **Deployment data:** load `dist/imd-deployment.json` at runtime for addresses and ABIs.
- **Swapping:** route swaps through the official Uniswap v4 Universal Router on Sepolia (or
  another official v4 router that forwards `hookData`).
- **Wallet flows:** handle wallet-not-connected, wrong network, insufficient balance, approvals
  and rejected transactions with short in-game messages.
- **Rules page:** a small rules panel explaining the pot, the roll, the golden flush, that this is
  Sepolia test value only, and the block-hash randomness caveat.
