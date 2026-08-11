# Clearing-House Settlement Token — Reference Model

A reference implementation of a common interbank settlement asset of the kind a
clearing utility (e.g. a TCH-style operator) would issue: a **par-valued,
permissioned token** with a **separate yield-accrual index**, an **obligation
netting engine**, and **atomic delivery-versus-payment** — plus the off-chain
netting optimiser and an economics simulator that measures, rather than asserts,
what the design is worth.

Self-contained: no proprietary dependencies, no external services. Solidity via
Foundry, Go with a pure-stdlib module.

---

## The three claims this repo makes executable

**1. Par is preserved while economics travel with the token.**
Both market-standard yield mechanisms break a settlement asset: exchange-rate
accrual (ERC-4626-style) pushes the unit off par so units minted at different
times stop being fungible; rebasing changes balances underneath every contract
holding one. `SettlementToken` keeps the unit at exactly one dollar and tracks
yield in a separate per-unit index, synced on both sides of every transfer — so
income credits **whoever held the token during each period**, not the original
contributor, and yield **never mints** (units with no reserve behind them would
break the backing invariant `totalSupply == reservePool`).

**2. Netting is impossible if submitting a payment moves tokens.**
`burn → mint → fail if short` is gross settlement; its efficiency is 1:1 by
construction. `NettingEngine` holds **obligations, not tokens**: submission
moves nothing, cycles settle only net positions, and any participant can pull an
obligation out for immediate gross settlement (`forceGross`) at the cost of
funding it in full.

**3. The chain does not trust the optimiser.**
Choosing which obligations to settle is a search problem and runs off-chain
(`internal/clearing`). Verifying the answer is a linear scan and runs on-chain:
`settleCycle` recomputes net positions from the discharged obligations and
rejects anything that does not follow from them. A compromised optimiser cannot
move value the obligations do not imply.

## Layout

| Path | What it is |
|---|---|
| `contracts/src/SettlementToken.sol` | Par token, ERC-7943 (uRWA) gate/freeze/force, accrual index, key-loss recovery |
| `contracts/src/NettingEngine.sol` | Obligation queue, verified net-settlement cycles, gross escape hatch |
| `contracts/src/AtomicDvP.sol` | Same-ledger asset-vs-cash: both legs in one transaction, or neither |
| `contracts/test/` | 22 Foundry tests pinning the invariants, incl. two audit regressions |
| `internal/clearing/` | Multilateral netting + gridlock resolution (feasible, deterministic plans) and the economics simulation |
| `cmd/clearing-operator/` | Prints the economics tables: efficiency and funding vs cycle size, accrual vs pool location |

## Run it

```bash
# Contracts (Foundry via Docker; or `forge test` if installed)
cd contracts && docker run --rm -v "$PWD":/w -w /w ghcr.io/foundry-rs/foundry:stable "forge test"

# Go: netting optimiser + simulation tests
go test ./...

# The economics tables
go run ./cmd/clearing-operator
```

Dependencies under `contracts/dependencies/` are soldeer-managed and not
committed; `forge soldeer install` restores them (pins in `foundry.toml`).

## Standards position

Built as plain OpenZeppelin ERC-20 + AccessControl, implementing the
**ERC-7943 (uRWA)** fungible interface — gate, freeze, forced transfer — with
two mechanisms ported from **ERC-3643**: key-loss recovery (`recoverBalance`)
and partial freeze. ERC-3643's full identity stack (six mandatory contracts plus
an ONCHAINID per holder) is deliberately not adopted: a settlement asset has a
few dozen holders, each an admitted institution under a legal agreement — a
membership list, not a claims registry. Expect the *securities* leg of a DvP to
be ERC-3643; the `AtomicDvP` asset leg is plain `IERC20` so such tokens work
unchanged, and their compliance checks propagate (an ineligible buyer reverts
both legs).

## Known limits, stated plainly

- **The obligation graph is public to chain participants** (payer, payee,
  amount). Deployable versions need commit-reveal, ZK netting, or a
  privacy-native venue. This gates any pilot.
- **No default waterfall.** Deferred settlement creates payee credit exposure
  between submit and cycle; a reverted cycle protects the ledger, not the payee
  who waited. Production needs net debit caps and loss-sharing rules.
- **Obligations do not expire**, and the operator can `forceGross` any queued
  obligation — needs TTLs and a payer-revocation window.
- **Plan-to-execution race:** balances can move between the optimiser's plan and
  `settleCycle`; the revert is atomic and safe, but production wants balance
  reservation.
- Gridlock resolution is a greedy heuristic (feasible and deterministic, not
  optimal). The simulator models random flow, not strategic queue management —
  batch cycles reach ~9:1 efficiency, not a CHIPS-like 29:1, and the netting
  ratio reduces intraday **turnover**, not end-of-day funding.
- Accrual is one-directional (no negative rates, no on-chain fees), and any
  contract that holds balances across time accrues yield to itself — forward
  entitlement or keep custody transient.
