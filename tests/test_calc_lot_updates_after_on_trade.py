import math


def calc_lot(base_lot: float, lot_factor: float, min_lot: float, max_lot: float, lot_step: float) -> float:
    lot_candidate = base_lot * lot_factor
    lot = lot_candidate
    lot_digits = 0
    if lot_step > 0:
        lot = round(lot / lot_step) * lot_step
        lot_digits = int(round(-math.log10(lot_step)))
        lot = round(lot, lot_digits)
    if lot < min_lot:
        lot = min_lot
    if lot > max_lot:
        lot = max_lot
    if lot_step > 0:
        lot = round(lot, lot_digits)
    return lot


class DummyState:
    def __init__(self):
        self.factor = 1.0

    def NextLot(self):
        return self.factor

    def OnTrade(self, win: bool):
        if win:
            self.factor += 1.0
        else:
            self.factor += 0.5


def test_calc_lot_reflects_updated_nextlot():
    state = DummyState()
    base_lot = 0.1
    min_lot = 0.01
    max_lot = 10.0
    lot_step = 0.01

    lot1 = calc_lot(base_lot, state.NextLot(), min_lot, max_lot, lot_step)
    state.OnTrade(True)
    lot2 = calc_lot(base_lot, state.NextLot(), min_lot, max_lot, lot_step)
    assert lot2 > lot1
