import math
import pytest


def pip_value(digits):
    point = 10 ** (-digits)
    return point * 10 if digits in (3, 5) else point


def tol(digits):
    return pip_value(digits) * 0.5


@pytest.mark.parametrize("digits", [5, 3])
def test_process_closed_trades_tolerance(digits):
    base = 1.23456 if digits == 5 else 123.456
    pip = pip_value(digits)
    tolerance = tol(digits)
    close_price = base
    take_profit = base + 0.4 * pip
    stop_loss = base - 0.4 * pip
    assert abs(close_price - take_profit) <= tolerance
    assert abs(close_price - stop_loss) <= tolerance
    take_profit_far = base + 0.6 * pip
    stop_loss_far = base - 0.6 * pip
    assert abs(close_price - take_profit_far) > tolerance
    assert abs(close_price - stop_loss_far) > tolerance


@pytest.mark.parametrize("digits", [5, 3])
def test_find_shadow_pending_tolerance(digits):
    base = 1.23456 if digits == 5 else 123.456
    pip = pip_value(digits)
    tolerance = tol(digits)
    target = base
    price_close = base + 0.4 * pip
    price_far = base + 0.6 * pip
    assert abs(price_close - target) <= tolerance
    assert abs(price_far - target) > tolerance


@pytest.mark.parametrize("digits", [5, 3])
def test_ensure_tpsl_tolerance(digits):
    base = 1.23456 if digits == 5 else 123.456
    pip = pip_value(digits)
    tolerance = tol(digits)
    desired = base
    current_close = base + 0.4 * pip
    current_far = base + 0.6 * pip
    assert abs(current_close - desired) <= tolerance
    assert abs(current_far - desired) > tolerance
