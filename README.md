# fix-settlement-recon

[![tests](https://github.com/stevenhatfield23@gmail.com/fix-settlement-recon/actions/workflows/tests.yml/badge.svg)](https://github.com/stevenhatfield23@gmail.com/fix-settlement-recon/actions/workflows/tests.yml)
[![python](https://img.shields.io/badge/python-3.10%2B-blue)](https://www.python.org/)
[![license](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![dependencies](https://img.shields.io/badge/runtime%20dependencies-none-brightgreen)](pyproject.toml)

**Reconciles FIX execution reports against on-chain stablecoin settlement.**

A trade executes on a venue and produces an `ExecutionReport` (35=8, 39=2). The
cash leg settles as an ERC-20 transfer on Ethereum or an L2. Something has to
prove the two match, decide when the settlement is safe to release against, and
tell an operations desk what to do when they don't.

**[Try it in your browser →](https://stevenhatfield23@gmail.com.github.io/fix-settlement-recon/)**
Six worked scenarios, one click each. Runs entirely client-side; no trade data
leaves the tab.

---

## Quickstart

```bash
git clone https://github.com/stevenhatfield23@gmail.com/fix-settlement-recon.git
cd fix-settlement-recon
python3 -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"

pytest -q                       # 63 tests
fix-recon --demo -v             # worked example with the runbook
./run.sh                        # the browser tool on :8000
```

Reconcile a break:

```bash
fix-recon --fix fills.txt --receipts receipts.json \
          --wallet ACME-FX=0x2222... --tolerance 25000000 -v
```

Build the same-day payments that discharge a day's fills:

```bash
fix-recon --instruct --fix fills.txt --wallets wallets.json \
          --from-wallet 0x1111... --nonce 4471 --cutoff 21:00 -v
```

Exit codes: `0` clean, `1` breaks found, `2` bad input — so it drops into cron
or CI without wrapping.

## What it does

**Reconcile** (`matcher.py`) — match settlements to fills, classify every break
with a severity and a first action.

**Instruct** (`instruct.py`) — the forward direction. Net a day's fills into
one payment per counterparty and emit an *unsigned* EIP-1559 transaction. Never
signs, never broadcasts, never touches a key.

**Compare** (`compare.py`) — field-by-field pairing of FIX tags against chain
fields, including the fields that have no counterpart on either side.

## The actual problem

A FIX fill and an ERC-20 transfer share no natural key. The chain has never
heard of an `ExecID`, and the transfer log has no field for one. Every design
decision below follows from that.

Matching runs in tiers, most reliable first, and every match carries a
confidence:

| Tier | Method | Confidence | Basis |
|---|---|---|---|
| 1 | Reference-linked | 1.00 | Venue emitted a settlement reference on both sides |
| 2 | Netted group | 0.90 | Several fills sum exactly to one transfer |
| 3 | One-to-one | 0.95 | Single fill, single transfer, exact amount |
| 4 | Bounded subset | 0.70 | Part of a netting group explains the transfer |

The engineering answer to a hard matching problem is usually to make the
upstream system emit a key. Tiers 2–4 exist because venues frequently don't, and
they are heuristics — which is why the report says so rather than pretending to
certainty it doesn't have.

## Things that are easy to get wrong

**The `to` field is the token contract, not the recipient.** The recipient lives
in calldata, or in `topics[2]` of the `Transfer` log. Reconciling on `to` matches
against the wrong party on every single transaction.

**Inclusion is not settlement.** A transaction can be mined, consume gas, and
move nothing — `status: 0x0`. The receipt status is checked before the log is
even looked at, and a reverted transaction produces a `TX_REVERTED` break rather
than looking like a missing payment.

**USDC has 6 decimals, not 18.** Every amount is held as integer minor units in
`TokenAmount`; there are no floats anywhere in the money path, and constructing
an amount with sub-minor-unit precision raises rather than silently rounding. The
reconciler also detects the specific case of two amounts differing by an exact
power of ten and names it `DECIMAL_SCALE_SUSPECT`, because that residual has one
cause and telling the desk "amounts differ" instead wastes an hour.

**`tx_hash` is not a settlement key.** One transaction can carry fifty clients'
transfers. The key is `tx_hash + log_index`, and gas is attributed once per
transaction rather than once per leg.

**Finality is not one thing.** Post-Merge Ethereum has real economic finality via
Casper FFG, so counting 12 confirmations is a pre-Merge habit — `rpc.py` exposes
the consensus-layer `finalized` tag, which is strictly better. Optimistic rollups
have a three-stage model: instant soft confirmation from a centralised sequencer,
L1 batch inclusion, then a seven-day fraud-proof window. Institutions do not wait
seven days; they accept at batch inclusion and carry sequencer risk explicitly.
That is a credit decision, not a technical one, so it lives in `chains.py` as a
`FinalityPolicy` where risk can see and change it.

**Settlement wallets are reference data, not message content.** A wallet address
arriving on the wire is a counterparty instruction about where to send money.
`WalletDirectory` is injectable and expected to be backed by an SSI service with
maker-checker on changes.

## Break taxonomy

A reconciler that returns a boolean is useless at 3am. Every break carries a
severity and a first action (`breaks.RUNBOOK`), and the codes are stable strings
you can build alerting and SLAs against.

Two asymmetries worth noting:

- An unmatched **obligation** is an operational failure — a payment probably
  didn't go out. Warning.
- An unmatched **transfer** is value leaving a firm wallet with no trade behind
  it. Critical, and routed to security rather than treasury.
- A transfer matching an obligation's amount and window but landing at a
  *different* wallet is not two unrelated gaps. It is `WRONG_RECIPIENT`, and
  collapsing it into two separate breaks is how misdirected funds get missed.

## FIX ↔ chain field mapping

| FIX | On-chain |
|---|---|
| 17 ExecID | — (no counterpart; hence the matching tiers) |
| 119 SettlCurrAmt | `Transfer` log `data`, ÷ 10^decimals |
| 120 SettlCurrency | resolved via token registry from contract address |
| 64 SettlDate | block timestamp |
| 60 TransactTime | — (venue-side only) |
| — | block number, confirmation depth, finality state |
| — | gas cost in ETH (a cost leg with no FIX representation) |

The gaps in that table are the interesting part. FIX models settlement as an
instruction with a date; a chain gives you a state that hardens over time. There
is no FIX field for "settled, but only three confirmations deep," which is
exactly why `SettlementState` exists as a first-class concept here.

## Integration

```python
obligations, rejects = obligations_from_messages(fix_messages, wallet_directory)
events = JsonRpcClient(RPC_URL, chain_id=1).settlement_events(tx_hash)
report = reconcile(obligations, events, ReconConfig(amount_tolerance_minor=25_000_000))

if report.critical:
    alert(report.summary())
narrative = llm.complete(report.to_agent_context())   # agent explains; engine decides
```

`to_agent_context()` is the hand-off into an LLM support agent. The deterministic
engine decides what broke and how bad; the model narrates it and drafts the
counterparty mail. The model is never asked to do the arithmetic — an LLM that
hallucinates a settlement amount is worse than no reconciler at all.

## Run it in a browser

`web/index.html` is a complete debugging tool that runs the reconciler
client-side under Pyodide. Two static files, no backend, and no trade data
ever leaves the browser — which is the only version of this tool anyone at a
bank would be permitted to paste a real execution report into.

That is possible only because this package has no runtime dependencies.

See `web/DEPLOY.md` for S3/CloudFront deployment, the Terraform objects, and
the Content-Security-Policy change Pyodide requires.

## Known limits

- `parse_fix` is a flat tag→value parse. Real `Parties` repeating groups
  (448/447/452) need a group-aware parser; settlement fields are top-level so
  this is sufficient here and deliberately not more.
- Subset matching is bounded (`max_subset_size`) rather than solving subset-sum.
  Unbounded search on a large netting group is exponential and would still be
  ambiguous.
- Token addresses in `chains.py` must be verified against the issuer's published
  contract list before production use. Load them from reference data, not source.
- Reorg detection requires the caller to supply canonical block hashes each
  polling cycle; there is no persistence layer here.
