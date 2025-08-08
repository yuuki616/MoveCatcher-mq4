import pathlib


def test_init_strategy_has_spread_check():
    mc_path = pathlib.Path(__file__).resolve().parents[1] / "experts" / "MoveCatcher.mq4"
    content = mc_path.read_text(encoding="utf-8")
    idx = content.find("bool InitStrategy()");
    assert idx != -1, "InitStrategyが見つからない"
    assert "SpreadExceeded" in content[idx:], "InitStrategyにスプレッド判定がない"
