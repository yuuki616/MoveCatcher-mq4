import pathlib


def test_recalculate_entry_levels_when_price_changes():
    mc_path = pathlib.Path(__file__).resolve().parents[1] / "experts" / "MoveCatcher.mq4"
    content = mc_path.read_text(encoding="utf-8")
    assert "double oldPrice = price;" in content, "旧価格の保存がない"
    assert "if(price != oldPrice)" in content, "価格変化チェックがない"
    after = content.split("if(price != oldPrice)")[1].split("distA = DistanceToExistingPositions(price);")[0]
    assert "entrySL = NormalizeDouble(price - PipsToPrice(GridPips), _Digits);" in after, "買い側のSL再計算がない"
    assert "entrySL = NormalizeDouble(price + PipsToPrice(GridPips), _Digits);" in after, "売り側のSL再計算がない"
    assert "entryTP = NormalizeDouble(price + PipsToPrice(GridPips), _Digits);" in after, "買い側のTP再計算がない"
    assert "entryTP = NormalizeDouble(price - PipsToPrice(GridPips), _Digits);" in after, "売り側のTP再計算がない"
