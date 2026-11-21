from pathlib import Path
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

BASE_DIR = Path(__file__).resolve().parents[2]
RAW_DIR = BASE_DIR / "experiments" / "raw-data"
ANALYSIS_DIR = BASE_DIR / "experiments" / "analysis"
FIGURES_DIR = BASE_DIR / "experiments" / "figures"

BENCHMARK_CSV = RAW_DIR / "benchmark_results.csv"
CPU_CSV = RAW_DIR / "cpu_metrics.csv"
SUMMARY_ANALYSIS_CSV = ANALYSIS_DIR / "summary_metrics.csv"
SUMMARY_EXP_CSV = BASE_DIR / "experiments" / "summary_metrics.csv"


def load_merged_data() -> pd.DataFrame:
    if not BENCHMARK_CSV.exists():
        raise FileNotFoundError(f"Chua tim thay file: {BENCHMARK_CSV}")

    bench_df = pd.read_csv(BENCHMARK_CSV)
    for col in ["run_id", "clients", "throughput_req_s", "avg_latency_ms", "p95_latency_ms", "error_rate_percent"]:
        if col in bench_df.columns:
            bench_df[col] = pd.to_numeric(bench_df[col], errors="coerce")

    bench_df["run_id"] = bench_df["run_id"].astype(int)
    bench_df["clients"] = bench_df["clients"].astype(int)

    if CPU_CSV.exists():
        cpu_df = pd.read_csv(CPU_CSV)
        for col in ["run_id", "clients", "avg_cpu_percent", "p95_cpu_percent", "avg_working_set_mb"]:
            if col in cpu_df.columns:
                cpu_df[col] = pd.to_numeric(cpu_df[col], errors="coerce")
        cpu_df["run_id"] = cpu_df["run_id"].astype(int)
        cpu_df["clients"] = cpu_df["clients"].astype(int)

        keep_cols = [c for c in ["run_id", "clients", "avg_cpu_percent", "p95_cpu_percent", "avg_working_set_mb"] if c in cpu_df.columns]
        merged = pd.merge(bench_df, cpu_df[keep_cols], on=["clients", "run_id"], how="left")
    else:
        merged = bench_df.copy()
        merged["avg_cpu_percent"] = np.nan

    return merged


def compute_summary(df: pd.DataFrame) -> pd.DataFrame:
    metrics = ["throughput_req_s", "avg_latency_ms", "p95_latency_ms", "avg_cpu_percent"]
    rows = []

    for clients, grp in df.groupby("clients", sort=True):
        row = {
            "clients": int(clients),
            "runs_count": int(len(grp)),
        }
        for m in metrics:
            s = grp[m].dropna() if m in grp.columns else pd.Series(dtype=float)
            if len(s) > 0:
                mean_val = float(s.mean())
                std_val = float(s.std(ddof=1)) if len(s) > 1 else 0.0
                cv_val = float((std_val / mean_val) * 100.0) if mean_val != 0 else 0.0
                row[f"{m}_mean"] = round(mean_val, 4)
                row[f"{m}_std"] = round(std_val, 4)
                row[f"{m}_cv_pct"] = round(cv_val, 2)
            else:
                row[f"{m}_mean"] = np.nan
                row[f"{m}_std"] = np.nan
                row[f"{m}_cv_pct"] = np.nan
        rows.append(row)

    return pd.DataFrame(rows).sort_values("clients").reset_index(drop=True)


def apply_style() -> None:
    plt.rcParams.update({
        "font.size": 11,
        "axes.titlesize": 13,
        "axes.titleweight": "bold",
        "axes.labelsize": 11,
        "legend.fontsize": 10,
        "figure.dpi": 300,
        "axes.grid": True,
        "grid.alpha": 0.3,
        "grid.linestyle": "--",
    })


def plot_throughput(summary: pd.DataFrame, out_path: Path) -> None:
    sub = summary.dropna(subset=["throughput_req_s_mean"])
    if sub.empty:
        return
    fig, ax = plt.subplots(figsize=(8, 5))
    ax.errorbar(
        sub["clients"],
        sub["throughput_req_s_mean"],
        yerr=sub["throughput_req_s_std"],
        fmt="-o",
        capsize=4,
        linewidth=2,
        markersize=6,
        label="Throughput (Mean ± Std)",
    )
    ax.set_title("Throughput vs. Concurrent Clients")
    ax.set_xlabel("Concurrent Clients")
    ax.set_ylabel("Throughput (req/s)")
    ax.set_xticks(sub["clients"])
    ax.legend()
    fig.tight_layout()
    fig.savefig(out_path, dpi=300)
    plt.close(fig)


def plot_latency(summary: pd.DataFrame, out_path: Path) -> None:
    has_avg = summary["avg_latency_ms_mean"].notna().any()
    has_p95 = summary["p95_latency_ms_mean"].notna().any()
    if not (has_avg or has_p95):
        return

    fig, ax = plt.subplots(figsize=(8, 5))
    if has_avg:
        sub_avg = summary.dropna(subset=["avg_latency_ms_mean"])
        ax.errorbar(
            sub_avg["clients"],
            sub_avg["avg_latency_ms_mean"],
            yerr=sub_avg["avg_latency_ms_std"],
            fmt="-o",
            capsize=4,
            linewidth=2,
            markersize=6,
            label="Average Latency (Mean ± Std)",
        )
    if has_p95:
        sub_p95 = summary.dropna(subset=["p95_latency_ms_mean"])
        ax.errorbar(
            sub_p95["clients"],
            sub_p95["p95_latency_ms_mean"],
            yerr=sub_p95["p95_latency_ms_std"],
            fmt="--s",
            capsize=4,
            linewidth=2,
            markersize=6,
            label="p95 Latency (Mean ± Std)",
        )
    ax.set_title("Round-Trip Latency vs. Concurrent Clients")
    ax.set_xlabel("Concurrent Clients")
    ax.set_ylabel("Latency (ms)")
    ax.set_xticks(summary["clients"])
    ax.legend()
    fig.tight_layout()
    fig.savefig(out_path, dpi=300)
    plt.close(fig)


def plot_cpu(summary: pd.DataFrame, out_path: Path) -> None:
    sub = summary.dropna(subset=["avg_cpu_percent_mean"])
    if sub.empty:
        return
    fig, ax = plt.subplots(figsize=(8, 5))
    ax.errorbar(
        sub["clients"],
        sub["avg_cpu_percent_mean"],
        yerr=sub["avg_cpu_percent_std"],
        fmt="-o",
        capsize=4,
        linewidth=2,
        markersize=6,
        label="Server CPU Utilization (Mean ± Std)",
    )
    ax.set_title("Server CPU Utilization vs. Concurrent Clients")
    ax.set_xlabel("Concurrent Clients")
    ax.set_ylabel("Server CPU Utilization (%)")
    ax.set_xticks(sub["clients"])
    ax.legend()
    fig.tight_layout()
    fig.savefig(out_path, dpi=300)
    plt.close(fig)


def main() -> None:
    apply_style()
    ANALYSIS_DIR.mkdir(parents=True, exist_ok=True)
    FIGURES_DIR.mkdir(parents=True, exist_ok=True)

    merged_df = load_merged_data()
    summary_df = compute_summary(merged_df)

    summary_df.to_csv(SUMMARY_ANALYSIS_CSV, index=False)
    summary_df.to_csv(SUMMARY_EXP_CSV, index=False)

    plot_throughput(summary_df, FIGURES_DIR / "throughput_vs_clients.png")
    plot_latency(summary_df, FIGURES_DIR / "latency_vs_clients.png")
    plot_cpu(summary_df, FIGURES_DIR / "cpu_vs_clients.png")

    print("Hoan tat phan tich du lieu.")
    print(f"Da xuat: {SUMMARY_ANALYSIS_CSV}")
    print(f"Da xuat: {SUMMARY_EXP_CSV}")
    print(f"Thu muc bieu do: {FIGURES_DIR}")
    print(summary_df.to_string(index=False))


if __name__ == "__main__":
    main()