# pepes armed with ai

A small browser game: a pepe walks a starry stage, pees on a fridge to swap tokens,
rolls for a jackpot, buys compute at a golden throne and climbs a pizza tower.

`prototype/` is the working game. Everything in it runs in the browser: balances, swaps,
prices and dice rolls are simulated. `SPEC.md` describes the on-chain version: a Uniswap v4
hook that feeds a jackpot from every swap, a token, and the site that plays against them
on Sepolia.

## Run the prototype

Serve the folder over HTTP (the music is loaded from `assets/`):

```sh
cd prototype && python3 -m http.server 8000
# open http://localhost:8000
```

Left and right arrows move and Up jumps. Space or `X` swings, pees (hold to aim, release to fire) or fires the climb jets. `T` flips the swap direction, `E` opens the golden throne (`1`-`3` buy, `Esc` closes), `C` cashes out of the climb, and `M` mutes the music.

## Status

- Prototype: complete, off-chain.
- On-chain release: specified in `SPEC.md`, built by the IMD swarm (https://imd.fun) on Sepolia.

## License

MIT, see `LICENSE`.
