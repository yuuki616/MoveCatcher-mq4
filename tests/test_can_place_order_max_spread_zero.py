import pathlib


def test_can_place_order_allows_zero_max_spread():
    mc_path = pathlib.Path(__file__).resolve().parents[1] / "experts" / "MoveCatcher.mq4"
    content = mc_path.read_text(encoding="utf-8")
    idx = content.find("bool CanPlaceOrder")
    assert idx != -1, "CanPlaceOrderが見つからない"
    end_idx = content.find("\ndouble ", idx + 1)
    if end_idx == -1:
        end_idx = len(content)
    fragment = content[idx:end_idx]
    assert "if(checkSpread && MaxSpreadPips > 0 && spread > MaxSpreadPips)" in fragment, "MaxSpreadPipsが0の場合にスプレッド判定を行わないようにする条件が不足"
    assert "if(checkSpread && spread > MaxSpreadPips)" not in fragment, "旧来のスプレッド判定が残っている"
