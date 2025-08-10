import pathlib
import re


def test_slippage_pips_used_for_all_orders():
    mc_path = pathlib.Path(__file__).resolve().parents[1] / "experts" / "MoveCatcherLite.mq4"
    code = mc_path.read_text(encoding="utf-8")

    # 新しい入力パラメータが存在する
    assert "input double SlippagePips" in code

    # RetryOrder が成行と指値の両方で呼ばれている
    assert "RetryOrder(false, positionTicket[SYSTEM_A]," in code
    assert "RetryOrder(false, ticketBuyLim, OP_BUYLIMIT" in code

    # SlippagePips をポイントへ換算し整数化した値を OrderSend で使用している
    assert "int slippage = (int)MathRound(SlippagePips * Pip / _Point)" in code
    m = re.search(r"OrderSend\([^;]*\);", code)
    assert m is not None
    assert "slippage" in m.group(0)
