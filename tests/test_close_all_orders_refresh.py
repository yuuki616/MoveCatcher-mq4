import pytest


def close_all_orders_py(orders, refresh_fail_tickets, initial_refresh_ok=True):
    if not initial_refresh_ok:
        return []
    processed = []
    for order in orders:
        ticket = order["ticket"]
        if ticket in refresh_fail_tickets:
            continue
        processed.append(ticket)
    return processed


def test_skips_failed_refresh_and_continues():
    orders = [
        {"ticket": 1},
        {"ticket": 2},
        {"ticket": 3},
    ]
    result = close_all_orders_py(orders, {2})
    assert result == [1, 3]


def test_aborts_when_initial_refresh_fails():
    orders = [
        {"ticket": 1},
        {"ticket": 2},
    ]
    result = close_all_orders_py(orders, set(), initial_refresh_ok=False)
    assert result == []
