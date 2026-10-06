"""
Chicago 311 ward wait-time dashboard.

Four views, each one answering a part of the same question. Deliberately not a
chart gallery: anything that did not change the recommendation was left out.

Run with:
    streamlit run dashboard/app.py
"""

from __future__ import annotations

from pathlib import Path

import duckdb
import matplotlib
import pandas as pd
import streamlit as st

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[1]
DB_PATH = REPO_ROOT / "data" / "chicago311.duckdb"
SCHEMA = "main_marts"

# One palette for the whole app, so the same thing is the same colour in every
# view. Ordered by hue so categorical series stay distinguishable in greyscale.
SLOW = "#B4443B"
FAST = "#2E6E8E"
NEUTRAL = "#7A8691"
ACCENT = "#C58A2E"
SIDE_COLORS = {"North": "#2E6E8E", "South": "#B4443B", "West": "#C58A2E"}

st.set_page_config(page_title="Chicago 311 ward wait times", layout="wide")


@st.cache_data(show_spinner=False)
def load(table: str) -> pd.DataFrame:
    # read_only so the dashboard can never be the thing that corrupts the
    # warehouse, and so it can run while dbt holds the file.
    con = duckdb.connect(str(DB_PATH), read_only=True)
    try:
        return con.execute("select * from " + SCHEMA + "." + table).df()
    finally:
        con.close()


def style(ax, xlabel: str = "", ylabel: str = "", title: str = "") -> None:
    ax.set_xlabel(xlabel, fontsize=9)
    ax.set_ylabel(ylabel, fontsize=9)
    if title:
        ax.set_title(title, fontsize=11, loc="left", pad=10)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    ax.spines["left"].set_color("#CCCCCC")
    ax.spines["bottom"].set_color("#CCCCCC")
    ax.tick_params(labelsize=8, length=0)
    ax.grid(axis="x", color="#EEEEEE", lw=0.8)
    ax.set_axisbelow(True)


if not DB_PATH.exists():
    st.error("No warehouse found at data/chicago311.duckdb. Run ./run.sh first.")
    st.stop()

ward_perf = load("mart_ward_service_performance")
svc = load("mart_service_type_summary")
vol = load("mart_volume_vs_delay")
trend = load("mart_monthly_trend")
dq = load("mart_data_quality")

st.title("Which Chicago wards wait longest, and is it because they ask for more?")
st.caption(
    "690,427 service requests, nine field-operations request types, "
    "January 2023 through December 2024. Source: Chicago Open Data, dataset v6vf-nfxy."
)

overall = vol[vol.service_type == "ALL SERVICES"].iloc[0]
k1, k2, k3, k4 = st.columns(4)
k1.metric("Requests analysed", f"{int(svc.requests_total.sum()):,}")
k2.metric(
    "Typical ward-service wait",
    f"{ward_perf.median_days_to_close.median():.1f} days",
    help="Median of the 450 ward-by-service medians. The request-level citywide "
         "median is 2.5 days, lower because the highest-volume service, graffiti, "
         "is also the fastest.",
)
k3.metric(
    "Ward volume vs wait",
    f"{overall.corr_ward_volume_vs_delay:+.2f}",
    help="Correlation across the 50 wards between total request volume and median wait. "
         "Negative means the busiest wards close work fastest.",
)
k4.metric(
    "Explained by ward",
    "4.9%",
    delta="service type explains 27.3%",
    delta_color="off",
    help="One-way R-squared on log closure time. See dbt/analyses/variance_decomposition.sql.",
)

st.divider()

tab1, tab2, tab3, tab4 = st.tabs(
    [
        "1. Is it volume?",
        "2. Which service, which ward",
        "3. Potholes: it is the season",
        "4. Data quality",
    ]
)

# ---------------------------------------------------------------------------
# View 1. The hypothesis test. The scatter is the whole argument.
# ---------------------------------------------------------------------------
with tab1:
    st.subheader("Busier wards are not slower wards")
    left, right = st.columns([3, 2])

    by_ward = (
        ward_perf.groupby(["ward", "ward_name", "city_side"], as_index=False)
        .agg(volume=("requests_total", "sum"), median_days=("median_days_to_close", "median"))
    )

    with left:
        fig, ax = plt.subplots(figsize=(7.5, 4.6))
        for side, grp in by_ward.groupby("city_side"):
            ax.scatter(grp.volume, grp.median_days, s=46, alpha=0.85,
                       color=SIDE_COLORS[side], label=side, edgecolor="white", lw=0.6)
        # Label only the wards a department head would ask about.
        for _, r in pd.concat([by_ward.nlargest(3, "median_days"),
                               by_ward.nlargest(2, "volume")]).iterrows():
            ax.annotate(r.ward_name, (r.volume, r.median_days), fontsize=7.5,
                        xytext=(5, 4), textcoords="offset points", color="#444444")
        style(ax, "Total requests filed, 2023-2024", "Median days to close",
              f"Correlation {overall.corr_ward_volume_vs_delay:+.2f}: the slope runs the wrong way for a queueing story")
        ax.legend(frameon=False, fontsize=8, title="Side", title_fontsize=8)
        st.pyplot(fig, width="stretch")
        plt.close(fig)

    with right:
        st.markdown(
            "If wards waited longer because they filed more, this cloud would slope "
            "upward. It slopes gently down. The two heaviest-volume wards are among "
            "the faster half of the city."
        )
        st.markdown("**Per service type, does volume predict the wait?**")
        show = vol[vol.service_type != "ALL SERVICES"][
            ["service_type", "corr_ward_volume_vs_delay", "volume_verdict"]
        ].sort_values("corr_ward_volume_vs_delay", ascending=False)
        show.columns = ["Service type", "Correlation", "Verdict"]
        st.dataframe(
            show.style.format({"Correlation": "{:+.2f}"})
            .background_gradient(subset=["Correlation"], cmap="RdBu_r", vmin=-0.7, vmax=0.7),
            hide_index=True,
            width="stretch",
        )
        st.caption(
            "Volume genuinely drives fly dumping. For abandoned vehicles and graffiti "
            "the relationship is negative."
        )

# ---------------------------------------------------------------------------
# View 2. What does drive the wait: the service, and for a few services, the ward.
# ---------------------------------------------------------------------------
with tab2:
    st.subheader("The service you asked for matters more than the ward you live in")
    left, right = st.columns(2)

    with left:
        s = svc.sort_values("median_days_to_close")
        fig, ax = plt.subplots(figsize=(6.4, 4.4))
        ax.barh(s.service_type, s.median_days_to_close, color=NEUTRAL, height=0.68)
        ax.barh(s.service_type.iloc[-1], s.median_days_to_close.iloc[-1], color=SLOW, height=0.68)
        for y, v in zip(range(len(s)), s.median_days_to_close):
            ax.text(v + 0.18, y, f"{v:.1f}d", va="center", fontsize=8, color="#333333")
        style(ax, "Citywide median days to close", "",
              "13x range across services, from graffiti to abandoned vehicles")
        ax.set_xlim(0, s.median_days_to_close.max() * 1.18)
        st.pyplot(fig, width="stretch")
        plt.close(fig)

    with right:
        s2 = svc.sort_values("ward_inequity_ratio")
        fig, ax = plt.subplots(figsize=(6.4, 4.4))
        colors = [SLOW if v >= 5 else NEUTRAL for v in s2.ward_inequity_ratio]
        ax.barh(s2.service_type, s2.ward_inequity_ratio, color=colors, height=0.68)
        ax.axvline(1, color="#999999", lw=1, ls="--")
        for y, v in zip(range(len(s2)), s2.ward_inequity_ratio):
            ax.text(v + 0.35, y, f"{v:.1f}x", va="center", fontsize=8, color="#333333")
        style(ax, "Slow ward median / fast ward median (p90 over p10)", "",
              "Ward inequity is concentrated in three services, not spread across all nine")
        ax.set_xlim(0, s2.ward_inequity_ratio.max() * 1.18)
        st.pyplot(fig, width="stretch")
        plt.close(fig)

    st.markdown("**Pick a service to see every ward**")
    chosen = st.selectbox("Service type", sorted(svc.service_type), index=0,
                          label_visibility="collapsed")
    detail = ward_perf[ward_perf.service_type == chosen].sort_values(
        "median_days_to_close", ascending=False
    )
    fig, ax = plt.subplots(figsize=(13.5, 3.6))
    ax.bar(detail.ward_name, detail.median_days_to_close,
           color=[SIDE_COLORS[s] for s in detail.city_side], width=0.78)
    city_med = svc.loc[svc.service_type == chosen, "median_days_to_close"].iloc[0]
    ax.axhline(city_med, color="#333333", lw=1.1, ls="--")
    ax.annotate(f"citywide median {city_med:.1f}d", (len(detail) - 0.5, city_med),
                fontsize=8, va="bottom", ha="right", color="#333333")
    style(ax, "", "Median days to close", f"{chosen}: every ward, slowest first")
    ax.grid(axis="y", color="#EEEEEE", lw=0.8); ax.grid(axis="x", visible=False)
    plt.xticks(rotation=90, fontsize=6.5)
    handles = [plt.Rectangle((0, 0), 1, 1, color=c) for c in SIDE_COLORS.values()]
    ax.legend(handles, SIDE_COLORS.keys(), frameon=False, fontsize=8, ncol=3)
    st.pyplot(fig, width="stretch")
    plt.close(fig)

# ---------------------------------------------------------------------------
# View 3. The actual mechanism behind the biggest delay, which is seasonal.
# ---------------------------------------------------------------------------
with tab3:
    st.subheader("Pothole waits peak when demand is lowest")
    p = trend[trend.service_type == "Pothole in Street Complaint"].sort_values("created_month")

    fig, ax = plt.subplots(figsize=(13, 4.4))
    ax.bar(p.created_month, p.requests_opened, width=22, color="#D9E2E8",
           label="Requests opened")
    style(ax, "", "Requests opened per month",
          "Volume peaks in February. The wait peaks in May, when volume has already fallen.")
    ax.grid(axis="y", color="#EEEEEE", lw=0.8); ax.grid(axis="x", visible=False)

    ax2 = ax.twinx()
    ax2.plot(p.created_month, p.median_days_to_close, color=SLOW, lw=2.2, marker="o",
             ms=4, label="Median days to close")
    ax2.set_ylabel("Median days to close", fontsize=9, color=SLOW)
    ax2.tick_params(labelsize=8, length=0, colors=SLOW)
    for side in ("top", "left"):
        ax2.spines[side].set_visible(False)
    ax2.spines["right"].set_color("#CCCCCC")

    h1, l1 = ax.get_legend_handles_labels()
    h2, l2 = ax2.get_legend_handles_labels()
    ax.legend(h1 + h2, l1 + l2, frameon=False, fontsize=8, loc="upper center", ncol=2)
    st.pyplot(fig, width="stretch")
    plt.close(fig)

    c1, c2 = st.columns([2, 3])
    with c1:
        feb = p[p.created_month.dt.strftime("%Y-%m") == "2024-02"].iloc[0]
        may = p[p.created_month.dt.strftime("%Y-%m") == "2024-05"].iloc[0]
        st.metric("Feb 2024", f"{feb.median_days_to_close:.1f} days",
                  f"{int(feb.requests_opened):,} requests", delta_color="off")
        st.metric("May 2024", f"{may.median_days_to_close:.1f} days",
                  f"{int(may.requests_opened):,} requests", delta_color="off")
        st.caption(
            "Volume fell 31% between those two months. The median wait rose from "
            "1.2 days to 62.9 days."
        )
    with c2:
        yoy = p.dropna(subset=["median_days_change_yoy"])
        fig, ax = plt.subplots(figsize=(7.4, 3.0))
        ax.bar(yoy.created_month, yoy.median_days_change_yoy, width=22,
               color=[SLOW if v > 0 else FAST for v in yoy.median_days_change_yoy])
        ax.axhline(0, color="#777777", lw=1)
        style(ax, "", "Change in median days vs same month 2023",
              "2024 off-season was far worse than 2023")
        ax.grid(axis="y", color="#EEEEEE", lw=0.8); ax.grid(axis="x", visible=False)
        st.pyplot(fig, width="stretch")
        plt.close(fig)

# ---------------------------------------------------------------------------
# View 4. The defects, because two of them change how the numbers above read.
# ---------------------------------------------------------------------------
with tab4:
    st.subheader("What is wrong with this data, and what was done about it")
    st.markdown(
        "Two of these change how the charts above should be read. **10.97% of all "
        "closures are recorded less than 60 seconds after the request was opened**, "
        "and for graffiti it is 32.9%. No crew removes graffiti in under a minute, "
        "so part of the graffiti median is administrative, not operational. Those "
        "rows are kept and flagged rather than deleted, because deleting them would "
        "make the remaining work look slower than it is."
    )

    table = dq[["defect_id", "defect", "affected_rows", "affected_share", "handling"]].copy()
    table.columns = ["#", "Defect", "Rows", "Share", "How the pipeline handles it"]
    st.dataframe(
        table.style.format({"Rows": "{:,.0f}", "Share": "{:.2%}"})
        .bar(subset=["Rows"], color="#E8D5C4"),
        hide_index=True,
        width="stretch",
    )

    fig, ax = plt.subplots(figsize=(7.2, 3.2))
    sub = svc.sort_values("share_closed_under_1min")
    ax.barh(sub.service_type, sub.share_closed_under_1min * 100,
            color=[SLOW if v > 0.1 else NEUTRAL for v in sub.share_closed_under_1min], height=0.68)
    for y, v in zip(range(len(sub)), sub.share_closed_under_1min * 100):
        ax.text(v + 0.5, y, f"{v:.1f}%", va="center", fontsize=8, color="#333333")
    style(ax, "Share of closures recorded in under 60 seconds", "",
          "Where the instant-closure problem lives")
    ax.set_xlim(0, 38)
    st.pyplot(fig, width="stretch")
    plt.close(fig)

    st.caption("Full write-up with the detection SQL for each defect: docs/DATA_QUALITY.md")

st.divider()
st.caption(
    "Built with dbt-duckdb. 9 models, 116 dbt tests including 6 singular tests. "
    "Marts exported to exports/*.csv for Tableau Public."
)
