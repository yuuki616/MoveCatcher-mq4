import pytest


def process_closed_trades_py(history, system, last_time, last_tickets):
    identifier = f"MoveCatcher_{system}"
    tickets = []
    times = []
    new_last_time = last_time
    new_last_tickets = list(last_tickets)
    for order in history:
        if not order["comment"].startswith(identifier):
            continue
        ct = order["close_time"]
        if ct < last_time:
            continue
        if ct == last_time and order["ticket"] in last_tickets:
            continue
        tickets.append(order["ticket"])
        times.append(ct)
        if ct > new_last_time:
            new_last_time = ct
            new_last_tickets = [order["ticket"]]
        elif ct == new_last_time:
            new_last_tickets.append(order["ticket"])
    return tickets, new_last_time, new_last_tickets


def test_same_time_closures_are_processed():
    history = [
        {"ticket": 1, "comment": "MoveCatcher_A_foo", "close_time": 100},
    ]
    tickets, last_time, last_tickets = process_closed_trades_py(history, "A", 0, [])
    assert tickets == [1]

    # 新しい注文が同一時刻で決済された場合でも処理されることを確認
    history.append({"ticket": 2, "comment": "MoveCatcher_A_bar", "close_time": 100})
    tickets, last_time, last_tickets = process_closed_trades_py(history, "A", last_time, last_tickets)
    assert tickets == [2]
    assert last_time == 100
    assert set(last_tickets) == {1, 2}

    # 既に処理済みの注文は再処理されないことを確認
    tickets, last_time, last_tickets = process_closed_trades_py(history, "A", last_time, last_tickets)
    assert tickets == []
    assert last_time == 100
    assert set(last_tickets) == {1, 2}
