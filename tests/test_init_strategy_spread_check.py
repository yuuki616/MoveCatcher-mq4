import pathlib


def test_init_strategy_logs_spread_without_check():
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
    init_body = "\n".join(lines[start_line:end_line])
    assert "PriceToPips(Ask - Bid)" in init_body, "スプレッド取得がない"
    assert "SpreadExceeded" not in init_body, "成行注文のスプレッド判定が残っている"
