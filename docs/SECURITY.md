# Sepolia security assumptions

**Sepolia game only. A mainnet version needs Chainlink VRF**, asynchronous request/fulfillment
accounting and independently reviewed timeout behavior instead of this future-block-hash scheme.
A block proposer can influence the hash, censor trades or draws, or reorder transactions. Public
winning tickets can be resolved selectively and earlier winners can consume pots before later
winners. Ticket creation, next-block randomness and prompt public settlement reduce neither
proposer control nor front-running to a mainnet-safe level. These are the approved Sepolia rules,
not a claim of secure valuable randomness.

## Custody and authority

PepeIce mints its fixed supply only in its zero-argument constructor to its deployer. There is no
owner, mint role, pause, burn extension, proxy, upgrade, delegatecall or selfdestruct. JackpotHook
has one immutable trusted PoolManager and no administrator, withdrawal key, fee setter or pause.
The deployment address encodes exactly `beforeSwap | beforeSwapReturnDelta` (`0x0088`). Other
hook selectors revert because they are absent. The factory is responsible for canonical pool
initialization, which is permissionless; only
the manager can invoke `beforeSwap` or `unlockCallback`.

Pots are segregated by the full v4 PoolId, with ETH/ICE ledgers backed by ERC-6909 claims. Shared
currencies aggregate at the manager but are accounted separately for prizes. A draw burns only
the recorded pool's debited claims. There is no user-supplied settlement callback payload: the
hook itself constructs it during `fillTank` or `draw`; the callback additionally requires an active
reentrancy guard. Hook state-changing entry points share that guard. Ticket flags and both pot
debits precede external transfers; failed settlement rolls back everything.

`hookData` specifies only the beneficiary of a paid ticket. `tx.origin` is the required fallback
beneficiary, never an authorization check. No router allowlist is necessary for this use: anyone
can pay for a ticket for any address. Frontends must explicitly encode the player's address when
using smart wallets/relayers. Wrong recipients cannot be repaired administratively. A recipient
that cannot receive native ETH can prevent its own jackpot from settling; others remain able to
swap/draw, and the failed ticket can eventually be expired. No alternate-recipient mechanism or
refund is provided by this specification.

## Return-delta accounting

The critical return-delta permission is needed to retain the 1% fee without withdrawing mid-swap.
This implementation also enforces full fills: inside `beforeSwap` it executes a self-initiated v4
swap for the fee-adjusted amount, checks its actual specified delta, and returns deltas that cancel
the outer swap and forward the complete trade. v4 suppresses self-hook callbacks. The actual
AMM calculation, not caller-supplied output, determines the opposite-currency delta. There is no
path accepting input while skipping AMM execution; partial fills revert. The only net hook gain
is the fixed fee, minted to claims. PoolManager enforces zero outstanding currency deltas when
the unlock ends. Tests include empty liquidity, one-sided startup, all four directions/modes and
price-limit failures. Integrators must account for the inner and outer manager swap events as
described in CONTRACTS.md. Router-specific quoting and event interpretation need fork rehearsal.

Amounts are checked before signed negation/casting. Fee calculations floor in minor units.
Golden-flush fees are bounded by signed-128-bit swap accounting; multiplication by 20 is safe.
Jackpot percentages use quotient/remainder arithmetic to avoid multiplication overflow while
retaining exact floor semantics. Trades outside supported v4 delta ranges revert. Claim redemption
uses v4's signed-128-bit per-operation amount bound, far above this release's fixed token supply
and Sepolia ETH funding.

## Asset and operational assumptions

The intended ERC20 is the deployed 18-decimal PepeIce. The single manager constructor does not
bind a token address: other initialized native/ERC20 pools can use this code with separate pots.
Only canonical pool addresses from the deployment service should be shown by the site. A hook
cannot protect PoolManager itself from an arbitrary malicious currency contract. Rebasing,
callback-bearing, blacklistable and transfer-tax tokens are unsupported. Tank funding checks
the exact amount settled and reverts if the manager receives less or more than promised. The
normal PepeIce has exact, callback-free transfers. Pool initialization is checked before tank
funding to avoid purchasing into an uninitialized pool.

There is no sweep mechanism. Direct token transfers, forced ETH and unsolicited claim transfers
are not credited to a pot and cannot be recovered. Users must fund through swaps or `fillTank`.
Tank purchases are irreversible donations in return for local gameplay. Draws require gas; an
operator or any player may resolve them during the documented window. There is no autonomous
scheduler in the contracts, no fixed payout reservation, and no liveness guarantee if nobody calls.
Monitor confirmed `TicketIssued`, `Drawn`, `TankFilled` events, unresolved ticket ages and claim
backing. Account for reorgs before granting local gameplay credits. Climb prizes remain local points.

This assignment supplies source, ABI exports, manifest and local tests. Local tests and local
review do not replace the separate independent adversarial review of the exact release artifact.
Services are responsible for that review, source publication, signed artifact and launch-policy
linkage, admission, real Sepolia manager/router rehearsal, CREATE2 deployment and pool setup.
No deployment or mainnet authorization is implied by these files. No live-chain rehearsal or
production randomness verification is claimed.
