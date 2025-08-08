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


def update_state_py(prev, exists):
    if exists:
        if prev == "Missing":
            return "MissingRecovered"
        return "Alive"
    if prev in ("Alive", "MissingRecovered"):
        return "Missing"
    return "Missing" if prev == "Missing" else "None"


def on_init_py(positions, corrector=correct_duplicate_positions_py):
    has_a = any(p["system"] == "A" for p in positions)
    has_b = any(p["system"] == "B" for p in positions)
    remaining, closed = corrector(positions)
    has_a = any(p["system"] == "A" for p in remaining)
    has_b = any(p["system"] == "B" for p in remaining)
    state_a = update_state_py(None, has_a)
    state_b = update_state_py(None, has_b)
    return remaining, closed, state_a, state_b


def test_duplicates_resolved_on_init():
    positions = [
        {"ticket": 1, "system": "A", "open_time": 1},
        {"ticket": 2, "system": "A", "open_time": 2},
        {"ticket": 3, "system": "B", "open_time": 1},
        {"ticket": 4, "system": "B", "open_time": 3},
    ]
    remaining, closed, _, _ = on_init_py(positions)

    assert len([p for p in remaining if p["system"] == "A"]) == 1
    assert len([p for p in remaining if p["system"] == "B"]) == 1
    assert {p["ticket"] for p in remaining} == {1, 3}
    assert {p["ticket"] for p in closed} == {2, 4}


def test_states_recomputed_after_correction():
    positions = [
        {"ticket": 1, "system": "A", "open_time": 1},
        {"ticket": 2, "system": "B", "open_time": 1},
    ]

    def remove_all(_):
        return [], positions

    remaining, closed, state_a, state_b = on_init_py(positions, corrector=remove_all)

    assert remaining == []
    assert closed == positions
    assert state_a == "None"
    assert state_b == "None"

