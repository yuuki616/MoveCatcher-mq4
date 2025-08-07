import math
import pytest


def normalize_lot(lot_candidate: float, min_lot: float, max_lot_broker: float, lot_step: float) -> float:
    lot = lot_candidate
    lot_digits = 0
    if lot_step > 0:
        lot = round(lot / lot_step) * lot_step
        lot_digits = int(round(-math.log10(lot_step)))
        lot = round(lot, lot_digits)
    if lot < min_lot:
        lot = min_lot
    if lot > max_lot_broker:
        lot = max_lot_broker
    return round(lot, lot_digits)


def clip_to_user_max(lot: float, user_max: float, lot_step: float) -> float:
    lot_digits = 0
    max_lot_adj = user_max
    if lot_step > 0:
        lot_digits = int(round(-math.log10(lot_step)))
        max_lot_adj = math.floor(user_max / lot_step) * lot_step
        max_lot_adj = round(max_lot_adj, lot_digits)
    result = lot
    if result > max_lot_adj:
        result = max_lot_adj
    if lot_step > 0:
        result = round(result, lot_digits)
    return result


def calc_lot(lot_candidate: float, user_max: float, min_lot: float, max_lot_broker: float, lot_step: float) -> float:
    lot_candidate = min(lot_candidate, user_max)
    lot_actual = normalize_lot(lot_candidate, min_lot, max_lot_broker, lot_step)
    lot_actual = clip_to_user_max(lot_actual, user_max, lot_step)
    return lot_actual


@pytest.mark.parametrize(
    "lot_candidate,user_max,min_lot,max_lot_broker,lot_step,expected",
    [
        (0.05, 1.0, 0.1, 10.0, 0.1, 0.1),
        (2.0, 1.5, 0.01, 10.0, 0.01, 1.5),
        (1.4, 1.45, 0.01, 2.0, 0.3, 1.2),
    ],
)

def test_calc_lot_respects_limits(lot_candidate, user_max, min_lot, max_lot_broker, lot_step, expected):
    lot = calc_lot(lot_candidate, user_max, min_lot, max_lot_broker, lot_step)
    assert lot == expected
    assert min_lot <= lot <= max_lot_broker
    assert lot <= user_max
    if lot_step > 0:
        assert abs(lot / lot_step - round(lot / lot_step)) < 1e-8
