import pathlib


def test_recover_after_sl_slippage_toggle():
    mc_path = pathlib.Path(__file__).resolve().parents[1] / "experts" / "MoveCatcher.mq4"
    code = mc_path.read_text(encoding="utf-8")
    assert "double reSlippagePips = SlippagePips;" in code
    assert "int    slippage = (int)MathRound(reSlippagePips * Pip() / Point);" in code
    assert "if(UseProtectedLimit)" in code
    assert "flagInfo = StringFormat(\"UseProtectedLimit=true slippage=%d\", slippage);" in code
    assert "flagInfo = StringFormat(\"UseProtectedLimit=false slippage=%d\", slippage);" in code
