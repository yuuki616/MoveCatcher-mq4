import pathlib
import re


def test_init_strategy_slippage_always_used():
    mc_path = pathlib.Path(__file__).resolve().parents[1] / "experts" / "MoveCatcher.mq4"
    code = mc_path.read_text(encoding="utf-8")
    m = re.search(r"bool InitStrategy\(\)[\s\S]*?int    slippage = ([^;]+);", code)
    assert m is not None
    expr = m.group(1)
    assert "Slippage()" in expr
    assert "UseProtectedLimit" not in expr

