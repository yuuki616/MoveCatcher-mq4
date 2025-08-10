README.md — MoveCatcher Lite for MT4（TP=実TP版）
2ポジ・等間隔ペアの超シンプル EA（方式B）
ロット = BaseLot × DMCMM 係数（A/B 完全独立）
TP/SL は実設定。決済後に DMCMM を反映して最新ロットで建て直し。

1. 概要
MoveCatcher Lite は、常時最大2本（A/B 各 0〜1 本）を目標に、2本並んだときの建値間隔 s = d/2（d=GridPips）を“できるだけ”維持する MT4 EA です。
TP と SL は実設定。決済を検知したら DMCMM に勝敗を反映 → 最新ロットでTPなら逆方向／SLなら同方向に成行で建て直します。
Pending は 初期の B 用 OCO（±s） と 欠落時の補充指値のみを使用します。

2. ファイル構成
swift
コピーする
編集する
/MQL4/Experts/MoveCatcherLite.mq4            ← EA 本体
/MQL4/Include/DecompositionMonteCarloMM.mqh  ← DMCMM（外部 or 同梱）
README.md
AGENTS.md
3. 動作環境
MetaTrader 4（最新推奨）

ヘッジ口座想定（FIFO/ノーヘッジは制約あり）

5桁/3桁ブローカー対応（Pip = 10*Point を考慮）

4. パラメータ
名称	型	例	説明
GridPips	double	100	d。各ポジの TP/SL 距離（pips）
BaseLot	double	0.10	実ロット = BaseLot × DMCMM 係数（0.01 刻み推奨）
MaxSpreadPips	double	2.0	“置く”前のみ判定（初期 B の OCO／欠落補充）。0 で無効
MagicNumber	int	246810	EA 識別用

内部派生値：s = GridPips / 2、Pip = (_Digits==3 || _Digits==5) ? 10*_Point : _Point

5. ロット（DMCMM）
A/B で 完全独立に lotFactor_sys = DMCMM(state_sys) を評価。

発注直前に毎回：actualLot = BaseLot × lotFactor_sys → ブローカー LotStep/Min/Max で丸め・クリップ。

本 Lite では MaxLot やロットリセット機構は未搭載（最小構成）。

6. 価格ルール（実TP/実SL）
指値は Buy=Ask 基準／Sell=Bid 基準。

TP/SL は実設定（エントリ基準で ±d。Ask/Bid は足さない）：

Long：TP=Entry+d（Bid 判定）／SL=Entry−d（Bid 判定）

Short：TP=Entry−d（Ask 判定）／SL=Entry+d（Ask 判定）

7. 使い方（流れ）
EA をチャートへ適用 → GridPips / BaseLot / MaxSpreadPips / MagicNumber を設定。

初期化：A を Market で 1 本（DMCMM(A) でロット決定）→ TP/SL=±d。
B は A 建値 ± s に OCO（置く直前に Spread チェック）。片側約定で片割れキャンセル → TP/SL=±d。

運用中：

TP（実TP）で決済 → Win 反映 → 最新ロットで逆方向に成行 → TP/SL=±d。

SL（実SL）で決済 → Loss 反映 → 最新ロットで同方向に成行 → TP/SL=±d。

1 本だけになったら、生存建値 ± s に 補充指値を 1 本（置く直前に Spread チェック）。

2 本生存中は Pending を持たないのが基本。欠落時のみ補充指値を置きます。

8. ログ（簡易）
Print などで最低限出力：
Reason{INIT,OCO_HIT,OCO_CANCEL,TP_REVERSE,SL_REENTRY,REFILL}, System(A/B), Entry/SL/TP, actualLot, Spread, Magic, Ticket
（勝敗カウントするなら：TP=Win / SL=Loss / その他=Neutral の単純ルールで OK）

9. 受け入れチェック
 初期：A=Market＋TP/SL、B=±s OCO（Spread OK）→ 片割れキャンセル

 TP（実TP）後：Win 反映 → 最新ロットで“逆方向”Market → 新ポジに ±d

 SL（実SL）後：Loss 反映 → 最新ロットで“同方向”Market → 新ポジに ±d

 2 本生存中は Pending なし／1 本時のみ補充

 BaseLot × DMCMM 係数が毎発注直前に A/B 独立で反映

 Spread 判定は置くときのみ

10. 割り切り・注意
同ティック完全反転は保証しません（MT4 の OnTick 検知＋実TP/実SLのため）。

ギャップ補正／距離帯フィルタ／生存同期リセット／MaxLot 等は未搭載（必要になったら拡張版へ移行）。

11. 推奨初期値
GridPips=100, BaseLot=0.10, MaxSpreadPips=2.0, MagicNumber=246810
時間足は M1〜M15 推奨（反応性向上）。

