# VETERANS — PoW NFT Mine with Wallet-Age Multipliers

Proof-of-work mined ERC721C collection on **Robinhood Chain (chain id 4663)**. 3,333 Pepe miners,
fixed 0.069 IMD mint price, ten difficulty epochs, wallet-age weighted staking, enforced 6.9%
royalties, and a trustless ETH/IMD claim pool. This repository is the contracts stage: Foundry
project, tests, ABI exports and this document. The frontend is a later stage.

## Contracts

| Contract            | Role                                                                                     |
|---------------------|------------------------------------------------------------------------------------------|
| `VeteransRenderer`  | Stateless on-chain metadata: pixel-art SVG + OpenSea JSON derived from the PoW hash.     |
| `VeteransNFT`       | ERC721C collection: `mint(nonce)`, epochs/difficulty, fee split, `firstSeen`, ERC-2981.  |
| `VeteransStaking`   | No-lock staking; 65% IMD share per mint, weighted by staked count × wallet-age multiplier. Deployed by `VeteransNFT`'s constructor. |
| `VeteransClaimPool` | Receives 20% of mint fees (IMD) and all royalties (ETH, WETH or IMD); stakers claim pro-rata by weight. Deployed by `VeteransNFT`'s constructor. |
| `WethUnwrapper`     | Tiny helper the pool deploys to turn WETH royalties back into ETH (WETH9 pays `withdraw` with a 2,300-gas stipend the pool cannot take directly). |

Source: `src/`. Tests: `test/`. ABIs: `docs/abi/<Contract>.json`. Reference deploy script:
`script/Deploy.s.sol` (its `deploy(owner)` function is what the tests exercise).

### Launch order and constructor arguments

| # | Contract            | Constructor arguments                                     |
|---|---------------------|-----------------------------------------------------------|
| 1 | `VeteransRenderer`  | none                                                      |
| 2 | `VeteransNFT`       | `owner` = `$owner`, `renderer` = `$contract:VeteransRenderer` |

`VeteransNFT`'s constructor creates `VeteransStaking(nft)` and `VeteransClaimPool(nft, staking)`
itself (and the pool creates its `WethUnwrapper`), binds them as immutables and sets the ERC-2981
royalty receiver to the pool. Nobody, including the owner, ever chooses where the fee split or the
royalties go. Their addresses are `VeteransNFT.staking()` and `VeteransNFT.claimPool()` and are
emitted in the `SiblingsDeployed` event at deployment; the frontend reads them from the NFT.
No constructor calls another contract, so the set deploys on an empty chain (the NFT's initcode is
about 27 KB, under EIP-3860's 49,152; its runtime about 12 KB).

Owner for this launch: `0x3d6a89c8751a45dd577a4c1f3b34e71c58236193`. The launch manifest
(`launch.json`) is written by the manifest step, not by this repository.

## After launch (owner's responsibilities)

1. **Set the IMD token (once).** Call `VeteransNFT.configure(imd, staking, claimPool)` from the
   owner wallet with the IMD ERC-20 token address on Robinhood Chain and, as confirmation of the
   handoff, the NFT's own `staking()` and `claimPool()` values. Any other address for either reverts
   with `InvalidSibling`: the arguments confirm the wiring, they cannot change it. The IMD address is
   not given in the brief and is not guessed: until `configure` runs, `mint` reverts with
   `NotConfigured`. The call is one-shot (`AlreadyConfigured` afterwards). `renounceOwnership` is
   refused before it, so a collection can never be left unable to mint.
2. **Set the chain's WETH (once).** Call `VeteransNFT.setWeth(weth)` with Robinhood Chain's
   canonical wrapped-ETH contract (from the chain's bridge / explorer documentation; verify `symbol()`
   is `WETH` and `deposit()` / `withdraw()` exist before calling). It lets anyone turn WETH royalties
   (marketplace offers settle in WETH) into ETH royalties through `VeteransClaimPool.unwrapWeth()`.
   Until it is set, WETH royalties wait in the pool untouched; nothing else depends on it.
3. **Set the ERC721C security policy on the transfer validator.** The default validator
   (`0x721C008fdff27BF06E7E123956E2Fe03B63342e3`, Limit Break's v4 `CreatorTokenTransferValidator`)
   has code on Robinhood Chain (checked against two public RPCs on 2026-10-14). From the owner wallet
   call on the validator: `setTransferSecurityLevelOfCollection(nft, level, …)` with the operator
   whitelist level (recommended level / level 3), and `applyListToCollection` with a list of
   royalty-honouring marketplaces. Staking and unstaking bypass the validator by design (ownership
   never changes), so the staking contract does not need to be whitelisted.
4. **Optionally freeze metadata.** `setRenderer` lets the owner upgrade the art until
   `freezeMetadata()` is called; freezing is irreversible.

## Economics (constants, not changeable)

| Parameter                | Value                                                                          |
|--------------------------|--------------------------------------------------------------------------------|
| Max supply               | 3,333, sequential token ids 1…3333                                             |
| Mint price               | 0.069 IMD, every epoch                                                         |
| Epochs                   | 10. Epochs 1–9 hold 333 mints each; epoch 10 runs to the cap (336 mints), because 10 × 333 = 3,330 and the brief fixes both numbers |
| Difficulty               | `START_BITS = 20` leading zero bits in epoch 1, `+1` bit per epoch (29 bits in epoch 10); target = `2^256 >> bits` |
| Fee split per mint       | 65% staking rewards · 20% claim pool · 10% treasury · 5% burn (exact wei amounts: 0.04485 / 0.0138 / 0.0069 / 0.00345 IMD) |
| Royalty                  | 690 bps to the claim pool; the pool forwards 90/690 (0.9% of the sale) to the treasury      |
| Treasury                 | `0xEab8865F6Af3a866FEf97a9A776c58aBcB711ab5` (no powers attached)              |
| Multipliers (wallet age) | 0–7 d 1.0× · 8–30 d 1.5× · 31–90 d 2.0× · 91–180 d 2.5× · 181–359 d 4.0× · 360+ d 8.0× |
| Overclocked odds         | 1 in 24 (seed byte 7 mod 24 == 0)                                             |
| Trait odds               | Per-100 tables in `VeteransRenderer`; a byte is scaled onto 0..99 (`byte × 100 / 256`), so the real odds match the tables to within a byte's 1/256 granularity |

Difficulty bits are a design choice the brief left open: 2^20 hashes is seconds in a browser, 2^29
is minutes to an hour on a GPU. Both are named constants in `VeteransNFT`.

## How it works

**Mining.** `hashFor(miner, nonce) = keccak256(abi.encodePacked(block.chainid, nft, miner, nonce))`.
`mint(nonce)` succeeds when the hash is below the current epoch target, the collection is not sold
out, and the wallet has not used that nonce before (a winning nonce is wallet-bound and single-use).
The mint pulls exactly 0.069 IMD via `transferFrom` (approve first), records `firstSeen` if unset,
assigns the next token id, stores the hash as the token's seed, and splits the fee in the same
transaction. Burning tries `burn(uint256)` on the IMD token and falls back to sending the 5% to
`0x…dEaD` if the token has no burn function.

**Views for the frontend.** `currentEpoch()`, `difficulty()` (bits), `target()`, `mintsRemainingInEpoch()`,
`remainingSupply()`, `mintPrice()`, `totalMinted()`, `hashFor()`, `isConfigured()`.

**Staking.** `stake(uint256[] ids)` (after `setApprovalForAll(staking, true)`) or
`safeTransferFrom(you, staking, id)`; `unstake(ids)`; `claim()` pays accrued IMD; `refresh(wallet)`
re-evaluates anyone's multiplier. Weight = staked count × multiplier (in tenths: 10…80).
Rewards use an accumulator (`accRewardPerWeight`, 1e27 precision); a wallet's pending reward is
settled at its old weight before any weight change. Rewards received while nothing is staked are
carried over and released to the first weight that appears (so rewards carried after the final mint,
when nothing can notify again, still reach stakers). Unstaking never forfeits accrued rewards. A plain
`transferFrom` into the staking contract is refused (`UseStakeOrSafeTransfer`) because it would
create no stake record; `stake()` and `safeTransferFrom` are the two staking paths.

**Claim pool.** ETH arriving through `receive()` is treated as a royalty: 90/690 is pushed to the
treasury (held in `treasuryOwed` and flushable by anyone with `payTreasury()` if the push fails),
the rest is distributed to stakers by weight. `donate()` gives ETH entirely to stakers. The 20%
IMD mint share is distributed the same way. `claimEth()`, `claimImd()`, `claimAll()`. Carry-over
(funds that arrived with no weight) is released to the first weight that appears. The pool has no
owner and no admin function. Weights are mirrored from the staking contract via `onWeightChange`,
which only the staking contract may call.

**Royalties paid in an ERC-20.** Marketplaces settle accepted offers in WETH and forward the royalty
as a WETH transfer to the pool; some may pay in IMD. Two permissionless functions recover them:
`unwrapWeth()` moves the pool's WETH balance through the `WethUnwrapper`, which unwraps it and sends
the ETH into `receive()` (normal royalty split; needs the owner's one-time `setWeth`); `syncImd()`
releases any IMD above what the pool owes stakers (`imdOwed`) as an IMD royalty, 90/690 to the
treasury and the rest to stakers. Any other ERC-20 sent to the pool is not recoverable.

**Metadata.** Fully on-chain. `tokenURI` returns a base64 JSON data URI with name, description,
inline SVG image and attributes: Background, Helmet, Headlamp, Eyes, Tool, Tier
(Veteran / Overclocked), Epoch (1–10; tokens 3331–3333 belong to epoch 10 like the contract's own
`currentEpoch`), Rarity Score. `VeteransRenderer.tokenJSON` returns the raw JSON.
The hash controls only visuals, never the token id. A global rarity *rank* needs the whole
collection and is computed off-chain from the on-chain scores (the frontend's job).

## Assumptions and design decisions

- **IMD is an ERC-20 with 18 decimals** on Robinhood Chain (the brief says "approve IMD"). Its
  address is owner-configured after launch; it is never a stand-in value.
- **"20% → ETH Claim Pool (converted or held as ETH)"** is implemented as *held*: the pool keeps the
  IMD and distributes it alongside royalty ETH. Swapping on-chain would add a DEX dependency and
  slippage/MEV exposure that the brief's "trustless, no admin keys" goal argues against.
- **Multipliers refresh on interaction.** The age tier is recomputed whenever a wallet stakes,
  unstakes, claims, or anyone calls `refresh(wallet)`. Between refreshes the last recorded tier
  applies. The frontend should call `refresh` when it sees a wallet cross a tier boundary.
- **No lock period.** The brief allowed "simple lock options or no lock — keep it clean".
- **Royalty receiver is the pool.** ERC-2981 reports a single receiver, so the pool receives the
  whole 6.9% and splits the treasury's 0.9% itself. Any ETH sent to the pool's `receive()` is treated
  as a royalty; use `donate()` to give ETH only to stakers.
- **Epoch 10 holds 336 mints** (see Economics).
- **Only staking paths bypass the transfer validator.** The staking contract moving tokens in or
  out, and a holder's own `safeTransferFrom` into it, keep the same beneficial owner and skip the
  validator. An operator moving someone else's token into the staking contract is validated like
  any other transfer, so a blocked marketplace gains nothing from that path.
- **IMD is a plain ERC-20** (no transfer fee, no rebasing). The fee split credits stakers for the
  amount it sends; a fee-on-transfer or rebasing IMD would leave the last claims short. The owner
  must confirm this before `configure`.
- **Miners can grind nonces for traits.** Traits derive from the winning hash as the brief requires,
  so a miner may discard winning nonces until one decodes to the traits they want (Overclocked costs
  about 24× the work). Price per token is unchanged.

## Trust assumptions (what the owner can and cannot do)

Can: `configure` once (the IMD address only: the staking and pool arguments must be the contracts
the NFT deployed itself); `setWeth` once; `setTransferValidator` (including `address(0)`, which
disables enforcement; the vendored `CreatorTokenBase` does not let a subclass forbid it),
`setAutomaticApprovalOfTransfersFromValidator` (never effective for tokens the staking contract
holds), and the collection's security policy on the validator; `setRenderer` until `freezeMetadata`;
`transferOwnership`; `renounceOwnership` once configured.
Cannot: change price, split, supply, epochs, difficulty, royalty rate or receiver, fee or royalty
destinations, multipliers, treasury; pause minting or staking; touch pool or staking funds. Those are
constants, immutables set by the constructor, or have no setter. Deployment pays no ETH and nothing
is upgradeable, proxied or self-destructible.

Known limits: ETH royalties sent with a 2,300-gas stipend (`transfer`) will revert because the
pool's `receive()` updates storage; marketplaces use `call` with full gas, and WETH's stipend is
handled by the `WethUnwrapper`. ERC-20 royalties other than WETH and IMD are not recoverable.

## Build and test

```
forge build
forge test
forge fmt --check
```

`foundry.toml` pins `solc = "0.8.26"`, `bytecode_hash = "none"`, optimizer on (200 runs), no
`ffi`, no filesystem permissions. Dependencies are vendored as plain files under `lib/`:
forge-std, OpenZeppelin Contracts 4.9.6, the ERC721C subset of Limit Break's
creator-token-standards (commit `980a63b`) and the PermitC constants file it imports.

Test suites (76 tests): `VeteransNFT.t.sol` (mint success/failure, fee split, burn fallback,
reentrancy, nonce reuse, wallet binding, sold out, full 3,333 mine-out through all epochs,
production 20-bit mine, metadata, validator enforcement, constructor-deployed siblings and the
rejection of any other sibling in `configure`, transfer guards, admin surface),
`VeteransStaking.t.sol` (multiplier table incl. fuzz, stake/unstake/claim, age weighting, refresh,
carry-over incl. release after the last mint, conservation), `VeteransClaimPool.t.sol` (royalty
split, carry-over, IMD share, claims, treasury fallback, reentrancy, stipend limit, `syncImd`,
`unwrapWeth` against a WETH9-style mock, conservation), `VeteransRenderer.t.sol` (fuzzed decode/render, Overclocked
rate, epoch clamp, trait odds), `Deploy.t.sol` (wiring, owner, forbidden opcodes, initcode size). Tests lower the difficulty
through a test double that overrides only `difficultyBits`; one test mines against the production
schedule. Run fuzz tests with `FOUNDRY_FUZZ_SEED=0xaa0b2f4b2349c5ff1790d8922c58279a3c4ce5051c91eba0e6a1065ec173b6de`
to match the verifier.

Passing tests are not an audit. The contracts hold user funds (IMD rewards, ETH royalties) and
need an independent adversarial review before release.

## Frontend notes (next stage)

Read everything from the ABIs in `docs/abi/`. The deployment handoff lists `VeteransRenderer` and
`VeteransNFT`; take the staking and pool addresses from `VeteransNFT.staking()` and
`VeteransNFT.claimPool()`. Mining in the browser: loop nonces, compute
`keccak256(abi.encodePacked(chainId, nft, wallet, nonce))` locally, submit the first hash below
`target()` through `mint(nonce)` after `IMD.approve(nft, 0.069e18)`. Wallet age and multiplier:
`VeteransNFT.firstSeen(wallet)`, `VeteransStaking.walletAge`, `currentMultiplier`, `weightOf`.
Pending rewards: `pendingReward`, `pendingEth`, `pendingImd`. Stats: `totalMinted`,
`totalRewardsReceived`, `totalEthReceived`, `totalEthToStakers`, `totalImdReceived`, `totalStaked`,
`totalWeight`. Gallery: `seedOf(tokenId)` + `VeteransRenderer.traitsOf(seed)` / `tokenJSON`.
