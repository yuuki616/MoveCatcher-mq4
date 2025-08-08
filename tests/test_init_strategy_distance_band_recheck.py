import pathlib


def test_init_strategy_rechecks_distance_band_after_price_refresh():
    mc_path = pathlib.Path(__file__).resolve().parents[1] / "experts" / "MoveCatcher.mq4"
    content = mc_path.read_text(encoding="utf-8")
    lines = content.splitlines()
    start_line = None
    end_line = None
    for i, line in enumerate(lines):
        if start_line is None and line.strip() == "bool InitStrategy()":
            start_line = i
        elif start_line is not None and line.startswith("void HandleOCODetectionFor"):
            end_line = i
            break
    assert start_line is not None, "InitStrategyが見つからない"
    assert end_line is not None, "HandleOCODetectionForが見つからない"
    init_body = lines[start_line:end_line]
    body_text = "\n".join(init_body)
    assert body_text.count("UseDistanceBand && distA >= 0") >= 2, "距離帯チェックが2回行われていない"
    refresh_idx = None
    for i, line in enumerate(init_body):
        if "RefreshRates" in line:
            refresh_idx = i
            break
    assert refresh_idx is not None, "RefreshRatesが見つからない"
    post_refresh = "\n".join(init_body[refresh_idx:])
    assert "UseDistanceBand && distA >= 0" in post_refresh, "価格更新後の距離帯チェックが不足"
