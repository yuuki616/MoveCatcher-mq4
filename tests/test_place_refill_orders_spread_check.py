import pathlib


def test_place_refill_orders_spread_check_present():
    mc_path = pathlib.Path(__file__).resolve().parents[1] / "experts" / "MoveCatcher.mq4"
    content = mc_path.read_text(encoding="utf-8")
    idx = content.find("bool PlaceRefillOrders")
    assert idx != -1, "PlaceRefillOrdersが見つからない"
    assert "Spread exceeded" in content[idx:], "PlaceRefillOrdersにスプレッド判定が必要"
