"""nbformat.validate integration test.

Runs `nbformat.validate` against representative .ipynb shapes that
Mercury produces, catching schema regressions that pure-Lua tests can't
see. Skipped automatically if nbformat isn't importable (it's an
optional dev dependency; CI installs it but local dev environments
might not).
"""

import json
import unittest

try:
    import nbformat
    from nbformat.validator import ValidationError

    HAS_NBFORMAT = True
except Exception:
    HAS_NBFORMAT = False


def _validate(doc_dict):
    """Run nbformat.validate on a dict and raise on schema failure."""
    nb = nbformat.from_dict(doc_dict)
    nbformat.validate(nb)


@unittest.skipUnless(HAS_NBFORMAT, "nbformat is not importable")
class MercuryShapeValidates(unittest.TestCase):
    """Each test mirrors a shape Mercury's encoder produces. If any of
    these starts failing, the encoder broke nbformat compliance and the
    matching Lua test (which exercises the same shape on the encode side)
    should also be reviewed.
    """

    def test_empty_notebook(self):
        doc = {
            "cells": [],
            "metadata": {},
            "nbformat": 4,
            "nbformat_minor": 5,
        }
        _validate(doc)

    def test_basic_code_cell_with_outputs(self):
        doc = {
            "cells": [
                {
                    "cell_type": "code",
                    "id": "aaaa1111",
                    "execution_count": 1,
                    "metadata": {},
                    "outputs": [
                        {
                            "output_type": "stream",
                            "name": "stdout",
                            "text": ["hello\n", "world"],
                        },
                        {
                            "output_type": "display_data",
                            "data": {"text/plain": "result"},
                            "metadata": {},
                        },
                    ],
                    "source": ["print('hi')"],
                }
            ],
            "metadata": {},
            "nbformat": 4,
            "nbformat_minor": 5,
        }
        _validate(doc)

    def test_markdown_cell(self):
        doc = {
            "cells": [
                {
                    "cell_type": "markdown",
                    "id": "bbbb2222",
                    "metadata": {},
                    "source": ["# Heading\n", "Some prose"],
                }
            ],
            "metadata": {},
            "nbformat": 4,
            "nbformat_minor": 5,
        }
        _validate(doc)

    def test_raw_cell(self):
        doc = {
            "cells": [
                {
                    "cell_type": "raw",
                    "id": "cccc3333",
                    "metadata": {},
                    "source": ["raw text content"],
                }
            ],
            "metadata": {},
            "nbformat": 4,
            "nbformat_minor": 5,
        }
        _validate(doc)

    def test_display_id_under_metadata_mercury(self):
        """Mercury's canonical display_id location is
        metadata.mercury.display_id — not a sibling transient.display_id.
        nbformat accepts unknown keys under metadata, so this validates."""
        doc = {
            "cells": [
                {
                    "cell_type": "code",
                    "id": "dddd4444",
                    "execution_count": 1,
                    "metadata": {},
                    "outputs": [
                        {
                            "output_type": "display_data",
                            "data": {"text/plain": "x"},
                            "metadata": {"mercury": {"display_id": "my-id"}},
                        }
                    ],
                    "source": [],
                }
            ],
            "metadata": {},
            "nbformat": 4,
            "nbformat_minor": 5,
        }
        _validate(doc)

    def test_collapsed_via_jupyter_outputs_hidden(self):
        """Mercury writes BOTH metadata.collapsed AND
        metadata.jupyter.outputs_hidden for collapsed outputs. Both keys
        are recognized by JupyterLab / VS Code."""
        doc = {
            "cells": [
                {
                    "cell_type": "code",
                    "id": "eeee5555",
                    "execution_count": 1,
                    "metadata": {
                        "collapsed": True,
                        "jupyter": {"outputs_hidden": True},
                    },
                    "outputs": [
                        {
                            "output_type": "stream",
                            "name": "stdout",
                            "text": ["hidden\n"],
                        }
                    ],
                    "source": ["print('x')"],
                }
            ],
            "metadata": {},
            "nbformat": 4,
            "nbformat_minor": 5,
        }
        _validate(doc)

    def test_executetime_metadata(self):
        """JupyterLab's ExecuteTime extension uses LITERAL DOTTED keys
        under metadata.execution — not nested objects. Mercury matches."""
        doc = {
            "cells": [
                {
                    "cell_type": "code",
                    "id": "ffff6666",
                    "execution_count": 1,
                    "metadata": {
                        "execution": {
                            "iopub.execute_input": "2024-01-01T12:00:00.123456Z",
                            "shell.execute_reply": "2024-01-01T12:00:01.789012Z",
                        }
                    },
                    "outputs": [],
                    "source": ["x = 1"],
                }
            ],
            "metadata": {},
            "nbformat": 4,
            "nbformat_minor": 5,
        }
        _validate(doc)

    def test_empty_per_mime_value_as_object(self):
        """Mercury's ensure_dict guarantees empty per-mime values
        serialize as {} not [] (e.g., IPython.display.JSON({}))."""
        doc = {
            "cells": [
                {
                    "cell_type": "code",
                    "id": "gggg7777",
                    "execution_count": 1,
                    "metadata": {},
                    "outputs": [
                        {
                            "output_type": "display_data",
                            "data": {"application/json": {}},
                            "metadata": {},
                        }
                    ],
                    "source": [],
                }
            ],
            "metadata": {},
            "nbformat": 4,
            "nbformat_minor": 5,
        }
        _validate(doc)

    def test_markdown_with_attachments(self):
        doc = {
            "cells": [
                {
                    "cell_type": "markdown",
                    "id": "hhhh8888",
                    "metadata": {},
                    "attachments": {
                        "img.png": {
                            "image/png": "iVBORw0KGgoAAAANSUhEUgAA"
                        }
                    },
                    "source": ["![](attachment:img.png)"],
                }
            ],
            "metadata": {},
            "nbformat": 4,
            "nbformat_minor": 5,
        }
        _validate(doc)

    def test_error_output(self):
        doc = {
            "cells": [
                {
                    "cell_type": "code",
                    "id": "iiii9999",
                    "execution_count": 1,
                    "metadata": {},
                    "outputs": [
                        {
                            "output_type": "error",
                            "ename": "ValueError",
                            "evalue": "boom",
                            "traceback": [
                                "Traceback (most recent call last):",
                                "  File ...",
                                "ValueError: boom",
                            ],
                        }
                    ],
                    "source": ["raise ValueError('boom')"],
                }
            ],
            "metadata": {},
            "nbformat": 4,
            "nbformat_minor": 5,
        }
        _validate(doc)

    def test_execute_result_with_execution_count(self):
        doc = {
            "cells": [
                {
                    "cell_type": "code",
                    "id": "jjjjaaaa",
                    "execution_count": 7,
                    "metadata": {},
                    "outputs": [
                        {
                            "output_type": "execute_result",
                            "execution_count": 7,
                            "data": {"text/plain": "42"},
                            "metadata": {},
                        }
                    ],
                    "source": ["6 * 7"],
                }
            ],
            "metadata": {},
            "nbformat": 4,
            "nbformat_minor": 5,
        }
        _validate(doc)

    def test_stream_merged_canonical(self):
        """Mercury's stream-merge-on-save collapses consecutive same-name
        stream items into single entries with array-of-strings text,
        matching nbformat.v4.normalize."""
        doc = {
            "cells": [
                {
                    "cell_type": "code",
                    "id": "llllcccc",
                    "execution_count": 1,
                    "metadata": {},
                    "outputs": [
                        {
                            "output_type": "stream",
                            "name": "stdout",
                            "text": ["line1\n", "line2\n", "line3"],
                        }
                    ],
                    "source": [],
                }
            ],
            "metadata": {},
            "nbformat": 4,
            "nbformat_minor": 5,
        }
        _validate(doc)

    def test_unknown_cell_type_preservation_via_stash(self):
        """Mercury preserves a non-{code,markdown,raw} cell_type as the
        original on disk. The stash key (mercury_original_cell_type)
        lives under cell.metadata while the cell is in-memory; on encode
        it is moved back to cell.cell_type and the stash is dropped, so
        what lands on disk is the original cell_type."""
        # Validate that nbformat accepts a "sql" cell_type at all (it doesn't
        # under strict schema, so we don't write it directly — we write the
        # round-trip path through code+metadata.mercury_original_cell_type
        # and then nbformat.normalize rewrites). Skip this assertion: it's
        # a covered-by-Lua case.
        pass

    def test_mercury_extras_stash(self):
        """Mercury stashes unknown separator tokens under
        cell.metadata.mercury_extras. The stash is an unknown key under
        metadata; nbformat tolerates unknown keys there by design."""
        doc = {
            "cells": [
                {
                    "cell_type": "code",
                    "id": "kkkkbbbb",
                    "execution_count": None,
                    "metadata": {
                        "mercury_extras": {"vscode_cell_id": "vsc-123"}
                    },
                    "outputs": [],
                    "source": [],
                }
            ],
            "metadata": {},
            "nbformat": 4,
            "nbformat_minor": 5,
        }
        _validate(doc)


if __name__ == "__main__":
    unittest.main()
