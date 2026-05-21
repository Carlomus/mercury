#!/usr/bin/env python3
"""Generate a notebook with three plots in one cell so the user can verify
that Mercury's image stacking does not overlap the plots.

Usage:
    python scripts/multi_image_demo.py /tmp/mercury_multi.ipynb
    nvim /tmp/mercury_multi.ipynb
    # Inside nvim:  Shift-Enter on the first cell

Requires: nbformat (always installed alongside jupyter_client).
"""

import json, os, sys, uuid


def cell(source, kind="code"):
    c = {
        "cell_type": kind,
        "id": uuid.uuid4().hex[:8],
        "metadata": {},
        "source": source,
    }
    if kind == "code":
        c["execution_count"] = None
        c["outputs"] = []
    return c


CODE = """\
import matplotlib
matplotlib.use("Agg")  # non-interactive
import matplotlib.pyplot as plt
import numpy as np

xs = np.linspace(0, 2 * np.pi, 200)
for i in range(1, 4):
    fig, ax = plt.subplots(figsize=(4, 2.4))
    ax.plot(xs, np.sin(i * xs))
    ax.set_title(f"sin({i}x)")
    plt.show()
"""

INTRO = """\
# Multi-image stacking demo

Run the next cell with Shift-Enter. You should see three plots stacked
below the cell, with no overlap. Each plot is its own image, anchored at
the cell body's last row with a distinct extmark column and an
incremental `render_offset_top`.
"""


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "/tmp/mercury_multi.ipynb"
    nb = {
        "cells": [cell(INTRO.splitlines(keepends=True), "markdown"),
                  cell(CODE.splitlines(keepends=True))],
        "metadata": {
            "kernelspec": {"name": "python3", "display_name": "Python 3",
                           "language": "python"},
            "language_info": {"name": "python"},
        },
        "nbformat": 4,
        "nbformat_minor": 5,
    }
    with open(out, "w") as f:
        json.dump(nb, f, indent=1)
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
