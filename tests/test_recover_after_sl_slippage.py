import pathlib


def test_recover_after_sl_slippage_conditional():
    mc_path = pathlib.Path(__file__).resolve().parents[1] / "experts" / "MoveCatcher.mq4"
    code = mc_path.read_text(encoding="utf-8")
    assert "int    slippage = UseProtectedLimit ? Slippage() : 2147483647;" in code
    assert "StringFormat(\"UseProtectedLimit=%s slippage=%d\"" in code
    assert "UseProtectedLimit ? \"true\" : \"false\"" in code
