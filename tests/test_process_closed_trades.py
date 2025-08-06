import pytest


def process_closed_trades_py(history, system, last_time):
    tickets = []
    times = []
    new_last_time = last_time
    for order in history:
        if order["system"] != system:
            continue
        ct = order["close_time"]
        if ct < last_time:
            continue
        tickets.append(order["ticket"])
        times.append(ct)
        if ct > new_last_time:
            new_last_time = ct
    return tickets, new_last_time


def test_same_time_closures_are_processed():
    history = [
        {"ticket": 1, "system": "A", "close_time": 100},
    ]
    tickets, last_time = process_closed_trades_py(history, "A", 0)
    assert tickets == [1]

    # 新しい注文が同一時刻で決済された場合でも処理されることを確認
    history.append({"ticket": 2, "system": "A", "close_time": 100})
    tickets, last_time = process_closed_trades_py(history, "A", last_time)
    assert 2 in tickets
    assert last_time == 100
