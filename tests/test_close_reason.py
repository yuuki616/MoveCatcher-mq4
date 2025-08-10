import pytest


def estimate_reason(order):
    point = order.get("point", 0.00001)
    tol = point * 1.0
    close_price = order["close"]
    tp = order.get("tp", 0)
    sl = order.get("sl", 0)
    typ = order.get("type", "buy")
    is_tp = False
    is_sl = False
    if typ == "buy":
        if tp > 0 and close_price >= tp - tol:
            is_tp = True
        if sl > 0 and close_price <= sl + tol:
            is_sl = True
    else:
        if tp > 0 and close_price <= tp + tol:
            is_tp = True
        if sl > 0 and close_price >= sl - tol:
            is_sl = True
    if is_tp:
        return "TP"
    if is_sl:
        return "SL"
    return "CLOSE"


def test_reason_detects_tp_sl_only():
    order_tp = {"close": 1.0002, "tp": 1.0002}
    order_sl = {"close": 0.9998, "sl": 0.9998}
    assert estimate_reason(order_tp) == "TP"
    assert estimate_reason(order_sl) == "SL"


def test_reason_returns_close_when_not_tp_sl():
    order = {"type": "buy", "open": 1.0, "close": 1.0001}
    assert estimate_reason(order) == "CLOSE"

