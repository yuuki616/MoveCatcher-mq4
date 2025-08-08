import pathlib
import re


def test_shadow_order_respects_distance_band():
    mc_path = pathlib.Path(__file__).resolve().parents[1] / "experts" / "MoveCatcher.mq4"
    content = mc_path.read_text(encoding="utf-8")
    pattern = r"CanPlaceOrder\s*\(\s*price\s*,\s*\(type == OP_BUYLIMIT\)\s*,\s*errcp\s*,\s*true\s*,\s*ticket\s*,\s*false\s*\)"
    assert re.search(pattern, content), "影指値では距離帯判定を行わない"
