import pathlib


def test_recover_after_sl_slippage_always_applied():
    mc_path = pathlib.Path(__file__).resolve().parents[1] / "experts" / "MoveCatcher.mq4"
    code = mc_path.read_text(encoding="utf-8")
    assert "double reSlippagePips = SlippagePips;" in code
    assert "int    slippage = (int)MathRound(reSlippagePips * Pip() / _Point);" in code
    assert "if(!UseProtectedLimit)" not in code
    assert "slippage = 0;" not in code
    assert "StringFormat(\"UseProtectedLimit=%s slippage=%d\"" in code
    assert "UseProtectedLimit ? \"true\" : \"false\"" in code
