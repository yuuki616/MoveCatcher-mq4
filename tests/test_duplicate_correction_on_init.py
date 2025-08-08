import pytest


def correct_duplicate_positions_py(positions):
    remaining = {}
    closed = []
    # sort by open_time to keep earliest position per system
    for pos in sorted(positions, key=lambda p: p["open_time"]):
        sys = pos["system"]
        if sys not in remaining:
            remaining[sys] = pos
        else:
            closed.append(pos)
    return list(remaining.values()), closed


def on_init_py(positions):
    # mimic the portion of OnInit that corrects duplicate positions
    return correct_duplicate_positions_py(positions)


def test_duplicates_resolved_on_init():
    positions = [
        {"ticket": 1, "system": "A", "open_time": 1},
        {"ticket": 2, "system": "A", "open_time": 2},
        {"ticket": 3, "system": "B", "open_time": 1},
        {"ticket": 4, "system": "B", "open_time": 3},
    ]
    remaining, closed = on_init_py(positions)

    assert len([p for p in remaining if p["system"] == "A"]) == 1
    assert len([p for p in remaining if p["system"] == "B"]) == 1
    assert {p["ticket"] for p in remaining} == {1, 3}
    assert {p["ticket"] for p in closed} == {2, 4}

