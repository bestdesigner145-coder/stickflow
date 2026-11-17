#!/usr/bin/env python3
"""Puts the summaries of the candidate reports side by side (spec 18.10 A5).

    scripts/combine-reports.py <folder with */summary.json and */facts.json> <out.md>

Ranks the models the app may download (up to about 3 GB): the two regressions
of the author's dictations first, then grouping, titles, junk and extra items,
found items, and speed last.
"""
import glob
import json
import os
import sys

LIMIT = 3.2e9


def main():
    folder, out = sys.argv[1], sys.argv[2]
    rows = {}
    facts = {}
    for path in glob.glob(os.path.join(folder, "**", "summary.json"), recursive=True):
        for summary in json.load(open(path)):
            rows.setdefault(summary["name"], summary)
        fact = os.path.join(os.path.dirname(path), "facts.json")
        if os.path.exists(fact):
            data = json.load(open(fact))
            facts[os.path.basename(os.path.dirname(path)).removeprefix("report-")] = data

    def share(part, whole):
        return f"{part}/{whole}" if whole else "—"

    def key(summary):
        b3 = sum(summary["regressions"].values())
        return (-b3, -summary["grouped"], -summary["titled"], summary["junk"] + summary["extra"],
                -summary["found"], summary["p50"])

    models = [s for s in rows.values() if s["bytes"] > 0]
    others = [s for s in rows.values() if s["bytes"] == 0]
    fitting = sorted([s for s in models if s["bytes"] <= LIMIT], key=key)
    lines = ["# Выбор встроенной модели (ТЗ 18.10, A5)", "",
             "| Провайдер | Размер | JSON | Группировка | Заголовок | Найдено | Лишние | Мусор | Дубли | Имена и числа | B3 "
             "| Прогрев | p50 | p95 |", "|" + "---|" * 14]
    for summary in sorted(models, key=key) + others:
        size = f"{summary['bytes'] / 1e9:.1f} ГБ" if summary["bytes"] else "—"
        b3 = f"{sum(summary['regressions'].values())}/{len(summary['regressions'])}"
        lines.append(
            f"| {summary['name']} | {size} | {share(summary['answered'], summary['cases'])} "
            f"| {share(summary['grouped'], summary['groupingCases'])} | {share(summary['titled'], summary['titleCases'])} "
            f"| {share(summary['found'], summary['expected'])} | {summary['extra']} | {summary['junk']} | {summary['duplicates']} "
            f"| {share(summary['kept'], summary['mustKeep'])} | {b3} | {summary['warmUp']:.1f} с "
            f"| {summary['p50']:.1f} с | {summary['p95']:.1f} с |")
    lines.append("")
    if fitting:
        best = fitting[0]
        lines.append(f"Первая по порядку из моделей до 3 ГБ: **{best['name']}**.")
        if best["name"] in facts:
            lines += ["", "```json", json.dumps(facts[best["name"]], indent=2, ensure_ascii=False), "```"]
    text = "\n".join(lines) + "\n"
    open(out, "w").write(text)
    print(text)


if __name__ == "__main__":
    main()
