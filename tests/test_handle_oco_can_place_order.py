import pathlib
import re


def test_handle_oco_uses_can_place_order():
    mc_path = pathlib.Path(__file__).resolve().parents[1] / "experts" / "MoveCatcher.mq4"
    content = mc_path.read_text(encoding="utf-8")
    pattern = r"CanPlaceOrder\s*\(\s*price\s*,\s*\(type == OP_BUY\)\s*,\s*errcp\s*\)"
    assert re.search(pattern, content), "HandleOCODetectionFor で CanPlaceOrder 呼び出しが必要"
