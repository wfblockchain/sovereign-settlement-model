// Command clearing-operator reports the economics of the settlement model.
//
// It runs a synthetic settlement day at several cycle sizes and prints what each
// costs a participant, so the operating trade-off is a table rather than an
// assertion.
//
//	go run ./cmd/clearing-operator
package main

import (
	"fmt"
	"math/big"
	"os"
	"text/tabwriter"

	"tch-settlement-model/internal/clearing"
)

const (
	dollar  = 1_000_000 // 6 decimals
	million = 1_000_000 * dollar
)

func main() {
	fmt.Println()
	fmt.Println("Settlement model — economics")
	fmt.Println("20 participants · 5,000 payments · skewed values · amply funded, so nothing defers")
	fmt.Println()

	w := tabwriter.NewWriter(os.Stdout, 0, 0, 3, ' ', 0)
	fmt.Fprintln(w, "cycle\tsettled\tgross settled\tvalue moved\tefficiency\tpeak drawdown")
	fmt.Fprintln(w, "-----\t-------\t-------------\t-----------\t----------\t-------------")

	// The cycle size is the operating dial. Small cycles settle fast and find
	// few offsets; large cycles find many and settle slowly. Nothing about the
	// contracts changes across these rows — only the operator's choice.
	for _, cycleSize := range []int{1, 10, 50, 200, 1000} {
		sim := clearing.Simulation{
			Participants:   20,
			Payments:       5000,
			MeanPayment:    big.NewInt(million),
			CycleSize:      cycleSize,
			OpeningBalance: new(big.Int).Mul(big.NewInt(5000), big.NewInt(million)),
			Seed:           42,
		}
		r, err := sim.Run()
		if err != nil {
			fmt.Fprintf(os.Stderr, "cycle size %d: %v\n", cycleSize, err)
			continue
		}
		fmt.Fprintf(w, "%d\t%d\t%s\t%s\t%.1f:1\t%s\n",
			cycleSize, r.Settled,
			usd(r.GrossSettled), usd(r.NetFunded), r.EfficiencyRatio(),
			usd(r.PeakFunding))
	}
	w.Flush()

	fmt.Println()
	fmt.Println("A cycle size of 1 IS gross settlement: every payment settles alone, and")
	fmt.Println("value moved equals value settled exactly. It is the row a burn-and-mint")
	fmt.Println("design produces, and the baseline the others are measured against.")
	fmt.Println()
	fmt.Println("Note what netting does and does not save. VALUE MOVED falls by ~9x, which")
	fmt.Println("is the liquidity turnover a participant must push through its account.")
	fmt.Println("PEAK DRAWDOWN barely moves, because it is driven by end-of-day net")
	fmt.Println("position, and netting does not change where a bank ends the day. A bank")
	fmt.Println("that is a net payer still funds that position either way; what it avoids")
	fmt.Println("is funding the gross outflow before the offsetting inflows arrive.")
	fmt.Println("Quoting a netting ratio as though it reduced end-of-day funding would be")
	fmt.Println("overclaiming.")

	// ── Accrual ───────────────────────────────────────────────────────────────
	fmt.Println()
	fmt.Println("Accrual on a $10bn pool, 30 days")
	fmt.Println()

	w = tabwriter.NewWriter(os.Stdout, 0, 0, 3, ' ', 0)
	fmt.Fprintln(w, "pool sits in\trate\tincome to distribute\tcost to participants")
	fmt.Fprintln(w, "------------\t----\t--------------------\t--------------------")

	pool := new(big.Int).Mul(big.NewInt(10_000), big.NewInt(million))
	for _, c := range []struct {
		where     string
		rateBps   int64
		earnsRate bool
	}{
		{"reserve account paying IORB", 400, true},
		{"non-interest-bearing account", 400, false},
	} {
		m := clearing.AccrualModel{PoolBalance: pool, AnnualRateBps: c.rateBps, Days: 30}
		income := m.PoolIncome()
		if !c.earnsRate {
			income = big.NewInt(0)
		}
		fmt.Fprintf(w, "%s\t%.2f%%\t%s\t%s\n",
			c.where, float64(c.rateBps)/100, usd(income),
			usd(m.SterilizationCost(c.earnsRate)))
	}
	w.Flush()

	fmt.Println()
	fmt.Println("The contract mechanism is identical in both rows. Which row is real")
	fmt.Println("depends on the account structure, which is a supervisory question and")
	fmt.Println("not one the token design can answer.")
	fmt.Println()
}

// usd renders base units as a readable dollar figure.
func usd(v *big.Int) string {
	f := new(big.Float).SetInt(v)
	f.Quo(f, big.NewFloat(dollar))
	d, _ := f.Float64()
	switch {
	case d >= 1e9:
		return fmt.Sprintf("$%.2fbn", d/1e9)
	case d >= 1e6:
		return fmt.Sprintf("$%.1fm", d/1e6)
	case d >= 1e3:
		return fmt.Sprintf("$%.1fk", d/1e3)
	default:
		return fmt.Sprintf("$%.0f", d)
	}
}
