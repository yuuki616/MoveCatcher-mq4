import pytest


def estimate_reason(order):
    point = order.get("point", 0.00001)
    tol = point * 0.5
    close_price = order["close"]
    tp = order.get("tp", 0)
    sl = order.get("sl", 0)
    is_tp = abs(close_price - tp) <= tol and tp > 0
    is_sl = abs(close_price - sl) <= tol and sl > 0
    if is_tp or is_sl:
        return "TP" if is_tp else "SL"
    comment = order.get("comment", "")
    comment_upper = comment.upper()
    if "TP" in comment_upper:
        return "TP"
    if "SL" in comment_upper:
        return "SL"
    open_price = order["open"]
    if order["type"] == "buy":
        return "TP" if close_price >= open_price else "SL"
    return "TP" if close_price <= open_price else "SL"


def test_reason_uses_price_when_profit_near_zero():
    buy_order = {"type": "buy", "open": 1.0, "close": 1.00001}
    assert estimate_reason(buy_order) == "TP"
    sell_order = {"type": "sell", "open": 1.0, "close": 0.99999}
    assert estimate_reason(sell_order) == "TP"
    buy_loss = {"type": "buy", "open": 1.0, "close": 0.99999}
    assert estimate_reason(buy_loss) == "SL"
    sell_loss = {"type": "sell", "open": 1.0, "close": 1.00001}
    assert estimate_reason(sell_loss) == "SL"


def test_reason_finds_tp_sl_in_comment_case_insensitively():
    tp_comment = {"type": "buy", "open": 1.0, "close": 0.5, "comment": "hit tp"}
    assert estimate_reason(tp_comment) == "TP"
    sl_comment = {"type": "buy", "open": 1.0, "close": 1.5, "comment": "via sl"}
    assert estimate_reason(sl_comment) == "SL"


def test_reason_falls_back_when_tp_sl_unset_and_close_price_zero():
    order = {"type": "buy", "open": 1.0, "close": 0.0}
    assert estimate_reason(order) == "SL"
