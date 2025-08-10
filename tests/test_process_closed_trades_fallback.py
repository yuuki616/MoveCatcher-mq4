import math


def detect_result(close_price, tp, sl, entry, order_type, grid_pips, pip, slippage_pips):
    tol = pip * slippage_pips
    is_tp = False
    is_sl = False
    if order_type == 'buy':
        if tp > 0 and close_price >= tp - tol:
            is_tp = True
        if sl > 0 and close_price <= sl + tol:
            is_sl = True
        tp_fallback = entry + grid_pips * pip
        sl_fallback = entry - grid_pips * pip
        if not is_tp and close_price >= tp_fallback - tol:
            is_tp = True
        if not is_sl and close_price <= sl_fallback + tol:
            is_sl = True
    else:
        if tp > 0 and close_price <= tp + tol:
            is_tp = True
        if sl > 0 and close_price >= sl - tol:
            is_sl = True
        tp_fallback = entry - grid_pips * pip
        sl_fallback = entry + grid_pips * pip
        if not is_tp and close_price <= tp_fallback + tol:
            is_tp = True
        if not is_sl and close_price >= sl_fallback - tol:
            is_sl = True
    return is_tp, is_sl


def test_fallback_triggers_tp_for_buy_when_tp_missing():
    entry = 1.0000
    pip = 0.0001
    d = 100 * pip
    close_price = entry + d
    is_tp, is_sl = detect_result(close_price, 0, entry - d, entry, 'buy', 100, pip, 1.0)
    assert is_tp and not is_sl


def test_fallback_triggers_sl_for_sell_when_sl_missing():
    entry = 1.0000
    pip = 0.0001
    d = 100 * pip
    close_price = entry + d
    is_tp, is_sl = detect_result(close_price, entry - d, 0, entry, 'sell', 100, pip, 1.0)
    assert not is_tp and is_sl
