import pathlib


def test_handle_oco_spread_check_removed():
    mc_path = pathlib.Path(__file__).resolve().parents[1] / "experts" / "MoveCatcher.mq4"
    content = mc_path.read_text(encoding="utf-8")
    idx = content.find("void HandleOCODetectionFor")
    assert idx != -1, "HandleOCODetectionForが見つからない"
    assert "SpreadExceeded" not in content[idx:], "HandleOCODetectionForにスプレッド判定が残っている"
