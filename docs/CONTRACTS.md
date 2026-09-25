# PepeIce and JackpotHook

This contribution implements SPEC.md sections 2.1–2.3 and the section 3 tests. It does not deploy
contracts or implement the website. Sepolia test value only, chain ID **11155111**. Sources and
original documentation are MIT; vendored dependencies retain their licenses.

## Build and reproduce

The existing ordinary-file dependencies in `lib/` are sufficient. No download, FFI, RPC, environment
file or filesystem cheatcode permission is needed. Use Foundry with the cached Solidity 0.8.26
compiler, Cancun EVM, optimizer 200 runs and the supplied `foundry.toml`/`remappings.txt`.

```sh
forge build --offline
forge test --offline
forge test --offline --fuzz-runs 1000
forge fmt --check
python3 tools/check_release.py
```

The final command checks manifest fields, constructor ABIs and the exported ABIs against the
compiler artifacts. The JSON files in `docs/abi/` are plain ABI arrays, extracted from the matching
`out/<Contract>.sol/<Contract>.json` artifacts, with no deployment addresses embedded.

## Launch parameters and responsibilities

| Item | Required value |
| --- | --- |
| Token | `src/PepeIce.sol:PepeIce`, constructor `()` |
| Name / symbol / decimals | `pepes ice` / `ICE` / `18` |
| Fixed supply | `10^27` minor units, all minted to the deploying factory |
| Hook | `src/JackpotHook.sol:JackpotHook`, constructor `(IPoolManager)` |
| Sepolia PoolManager | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| Hook flags | `beforeSwap` and `beforeSwapReturnDelta`, `0x0088` (136) |
| Hook address check | `uint160(address) & 0x3fff == 0x0088` |
| currency0 / currency1 | native ETH (zero address) / deployed PepeIce |
| LP fee / tick spacing | 3000 (0.3%) / 60 |
| sqrtPriceX96 | `79228162514264337593543950336000` |
| Initial ratio | 1,000,000 ICE per ETH, both using 18 decimal places |

The hook constructor validates all 14 permission bits. Mine a CREATE2 salt from the **actual
deployment factory**, the final creation bytecode and the ABI-encoded PoolManager argument.
The address is the low 20 bytes of
`keccak256(0xff || create2Factory || salt || keccak256(initCode))`.
Compiler or constructor changes invalidate a previously mined salt. Tests use actual CREATE2
deployment and constructor validation, not an etched hook or disabled permission check.

The factory may initialize the pool without being a special sender. No initialization hook is
enabled. The factory must receive the entire token supply and apply the versioned policy's
allocations. Supply, allocations and policy linkage are deliberately absent from `launch.json`.
The manifest follows the shape of the
[specified launch-124 reference](https://github.com/identity-md-launches/launch-124-workflow-contract-stage-context/blob/main/launch.json).

Release services publish source, bind signed artifacts and policy, obtain independent review,
perform fork rehearsal, admit the launch, mine/deploy it and initialize/seed the pool. They must
verify the real Sepolia manager code, network, token address, permissions and initialization
parameters before broadcasting. No transaction, deployment approval or funded-wallet operation is
part of this contribution. The deployment service then supplies addresses and these ABIs to the
frontend through `imd-deployment.json`.

## Swap accounting

For `A = abs(amountSpecified)` and `F = floor(A * 100 / 10000)`, the fee currency is:

| zeroForOne | Mode | Specified currency | AMM specified amount | Trader specified delta |
| --- | --- | --- | --- | --- |
| true | exact input | ETH | `-(A-F)` | `-A` |
| false | exact input | ICE | `-(A-F)` | `-A` |
| true | exact output | ICE | `A+F` | `+A` |
| false | exact output | ETH | `A+F` | `+A` |

LP/protocol fees are still calculated by v4 on the adjusted AMM trade. The opposite currency
amount follows the pool's price and liquidity; it is subject to the router's slippage constraints.
Amounts below 100 minor units have zero pot fee. All arithmetic rounds down as specified.

A fee-only `beforeSwap` return cannot observe a later partial fill. To enforce the acceptance
requirement for every successful swap, this hook calls the same manager's `swap` with the adjusted
amount and original price limit, verifies the complete specified delta, then offsets the outer
swap in full. v4 skips hook callbacks when the swap caller is that hook; there is no recursive
ticket issuance. The returned unspecified delta forwards only the actual AMM result.
No external router or arbitrary call target is invoked by the hook. Empty liquidity or a price
limit that prevents a complete fill reverts atomically, including fee claims and tickets.

The accounting identity is `inner AMM delta + outer hook delta - minted fee = 0` in each currency.
The hook never releases funds mid-swap. Its only remaining asset is exactly `F` in manager claims.
The manager's unlock settlement proves there is no unpaid hook delta. This is the same fee
economics as the reference burn hook, with full-fill enforcement and retained claims.

Indexers must expect two manager `Swap` events: the real inner AMM event (sender is the hook) and
the zero-amount outer event (sender is the router). Count `TicketIssued` once per eligible trade;
do not interpret the outer event's zero amounts as the trader's settlement. Routers receive the
correct combined `BalanceDelta`. The browser should use an official v4 router that forwards
`hookData` and validates minimum output / maximum input.

## ABI and game integration

`PoolId` is the v4 hash of the entire `PoolKey` (currencies, fee, tick spacing and hook).
Pool balances and tickets are isolated by this ID, even for pools sharing the same currencies.
Only native/ERC20 pools using this hook can swap or fill a tank. The release ICE address is a
deployment choice: the one-argument hook has no token allowlist. See SECURITY.md for assumptions.

* `pots(PoolId) -> (uint256 eth, uint256 ice)`: minor-unit pot amounts, excluding unsolicited gifts.
* `nextTicketId(PoolId) -> uint256`: next unused ID, initially zero. IDs run from zero through
  `nextTicketId - 1`, independently per pool.
* `ticket(PoolId, uint256) -> Ticket`: tuple `(player, currency, fee, blockNumber, drawn)`;
  nonexistent IDs revert `UnknownTicket`.
* `draw(PoolId, uint256)`: permissionless; sends any prize to the ticket's player. Emits
  `Drawn(poolId, ticketId, player, roll, payoutEth, payoutIce)`. Expiry uses `roll=0`; other rolls
  are 1–100. Repeated draws revert `AlreadyDrawn`.
* `fillTank(PoolKey, uint256 pees)`: approve the hook, then buy 1–1000 pees. Exactly
  `pees * 10e18` ICE moves from the caller to PoolManager and is minted into the hook's claims.
  Requires an initialized native/ERC20 pool. Emits `TankFilled(poolId, player, pees)`.
  It issues no lottery ticket and stores no on-chain pee count. The site credits only confirmed
  events and counts down pees locally. There is no refund or tank withdrawal.

An eligible swap fee is at least `1e13` wei ETH or `1e18` minor units ICE. Encode the intended
recipient as exactly one 32-byte ABI address in `hookData`. Any other data length uses
`tx.origin`, as required by the spec; it is never used for authorization. With smart-account
routers, explicitly encoding the recipient avoids awarding a relayer. An invalid ABI address word
reverts an eligible swap. A zero or non-receiving player address is permitted by the specified
attribution rule; the sender must choose a usable recipient. Ticket IDs and data are emitted in
`TicketIssued(poolId, ticketId, player, currency, fee, blockNumber)`.

## Ticket lifecycle and payouts

Each ticket is a separate draw, with no global round closure and no late-entry race. For ticket
block **B**, blocks B and B+1 are too early: the hash of B+1 is available starting at **B+2**.
The inclusive resolution window is **B+2 through B+256**. At **B+257** and later the ticket
expires, is marked drawn and pays zero. Age is measured from the ticket block, not the hash block.

The roll is exactly
`uint256(keccak256(abi.encode(blockhash(B+1), poolId, ticketId))) % 100 + 1`.
This is ABI encoding, not packed encoding. A 77 pays floor(90% of each current pot). Rolls
20/40/60/80/100 pay `min(20 * ticket.fee, floor(10% of the current fee-currency pot))`.
Other rolls pay zero. Remaining claims seed subsequent draws. The pot at settlement, including
intervening swaps/tank purchases and earlier payouts, determines the prize; no pot is reserved at
ticket issuance. Anyone may resolve tickets, so ordering matters.

Winning draws debit the pots and mark the ticket before entering `poolManager.unlock`, burn the
matching claims, and `take` both assets directly to the recipient. A failed transfer reverts the
entire draw, leaving the ticket retryable within its window. On expiry it can be resolved without
calling the receiver. There is no keeper privilege, alternate recipient or administrative recovery.

## Test coverage

`PepeIce.t.sol` checks metadata, supply, exact transfers/allowances and rejected unauthorized
operations. `JackpotHook.t.sol` exercises the real v4 manager, all four swap modes and price-limit
failures, rounding, attribution/thresholds, permissions, constructor flags, draw windows and
outcomes, duplicate/missing tickets and tank validation. `JackpotAdversarial.t.sol` checks payment
rollback/retry, reentrancy, pool isolation, rejected transfer-tax funding and an all-ICE initial
liquidity position through first buy, first sell and LP withdrawal. `JackpotConservation.t.sol`
fuzzes 40-step sequences of swaps, tank fills, winning/losing/expired/repeated draws and checks
actual payouts plus remaining claims equal all amounts received in each currency after every step.

Tests use controlled block hashes solely to reach every outcome. They demonstrate accounting,
not production randomness or a deployed router integration. Independent release review and fork
rehearsal remain service responsibilities. See [VALIDATION.md](VALIDATION.md) for commands,
results, advisory review and source fingerprints.
