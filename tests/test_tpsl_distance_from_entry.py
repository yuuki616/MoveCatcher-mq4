import pathlib


def test_ensure_tpsl_distance():
    mc_path = pathlib.Path(__file__).resolve().parents[1] / "experts" / "MoveCatcher.mq4"
    content = mc_path.read_text(encoding="utf-8")
    ensure_block = content.split("void EnsureTPSL")[1]
    assert "desiredSL = isBuy ? entry - PipsToPrice(GridPips) : entry + PipsToPrice(GridPips);" in ensure_block
    assert "desiredTP = isBuy ? entry + PipsToPrice(GridPips) : entry - PipsToPrice(GridPips);" in ensure_block
    assert "desiredSL = Bid - minDist" not in ensure_block
    assert "desiredTP = Bid + minDist" not in ensure_block
    assert "desiredSL = Ask + minDist" not in ensure_block
    assert "desiredTP = Ask - minDist" not in ensure_block


def test_recover_after_sl_distance():
    mc_path = pathlib.Path(__file__).resolve().parents[1] / "experts" / "MoveCatcher.mq4"
    content = mc_path.read_text(encoding="utf-8")
    assert "sl       = NormalizeDouble(isBuy ? price - PipsToPrice(GridPips) : price + PipsToPrice(GridPips), Digits);" in content
    assert "tp       = NormalizeDouble(isBuy ? price + PipsToPrice(GridPips) : price - PipsToPrice(GridPips), Digits);" in content
    assert "sl = isBuy ? price - minLevel : price + minLevel" not in content
    assert "tp = isBuy ? price + minLevel : price - minLevel" not in content
    assert "double desiredSL = isBuy ? entry - PipsToPrice(GridPips) : entry + PipsToPrice(GridPips);" in content
    assert "double desiredTP = isBuy ? entry + PipsToPrice(GridPips) : entry - PipsToPrice(GridPips);" in content
    assert "desiredSL = Bid - minLevel" not in content
    assert "desiredTP = Bid + minLevel" not in content
    assert "desiredSL = Ask + minLevel" not in content
    assert "desiredTP = Ask - minLevel" not in content
