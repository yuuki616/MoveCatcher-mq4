import pathlib


def test_no_market_slippage_parameter():
    mc_path = pathlib.Path(__file__).resolve().parents[1] / "experts" / "MoveCatcher.mq4"
    content = mc_path.read_text(encoding="utf-8")
    assert "MarketSlippagePips" not in content
