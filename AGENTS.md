# AGENTS.md — MT4 EA 実装指示書（Lite・TP=実TP版・修正版）

**Project:** MoveCatcher Lite（方式B／2系統 A/B・独立）
**Target:** MetaTrader 4（MQL4）
**方針:** ギャップ補正・距離帯・各種リセットなし。TP/SL は実設定。ロットは DMCMM × BaseLot を**発注直前**に毎回評価。A/B は完全独立。
**修正要旨:** 勝敗判定はEA本体が行い、判定結果を DMCMM（MQH）へ `winStep()` / `loseStep()` で明示的に反映することを明記。

---

## 1) 目的 / ミッション

同時最大2本（A/B 各 0〜1 本）を基本に、2本同時保有時の建値間隔 **s = d/2**（d=TP/SL 距離）を「できるだけ」維持。
**TP（実TP）決済後は逆方向に成行で建て直し、SL（実SL）決済後は同方向に成行で建て直す。**
ロットは **DMCMM（DecompositionMonteCarloMM.mqh）** 準拠：
**実ロット = BaseLot ×（DMCMM 係数）**。A/B の DMCMM 状態は完全独立に保持・更新。

## 2) 実行環境 / 制約

* MT4 / MQL4（`OnInit` / `OnTick` / `OnDeinit`）。`OnTradeTransaction` は無し → **OnTick で履歴差分検知**。
* 価格保護は必要最小限（slippage 固定でも可）。
* ヘッジ口座前提。FIFO/ノーヘッジの場合の制約はこの Lite では非対応。

## 3) 入力パラメータ（最小）

| 名称            | 型      | 例      | 説明                                   |
| ------------- | ------ | ------ | ------------------------------------ |
| GridPips      | double | 100    | d。各ポジの TP/SL 距離（pips）                |
| BaseLot       | double | 0.10   | 実ロット = BaseLot × DMCMM 係数（0.01 刻み推奨） |
| MaxSpreadPips | double | 2.0    | **“置く”前だけ**チェック（初期BのOCO／欠落時補充）。0で無効  |
| MagicNumber   | int    | 246810 | EA 識別用                               |

**内部派生値**

* `s = GridPips / 2`
* `Pip = (_Digits==3 || _Digits==5) ? 10*_Point : _Point`

## 4) コメント／ラベル

* 系統識別コメント：**MoveCatcher\_A / MoveCatcher\_B**
* すべての注文・ポジションに付与（**系統判定はコメント**で実施）。

## 5) DMCMM 連携・ロット算出

* **抽象 I/F:** `lotFactor_sys = DMCMM(state_sys)`（`sys ∈ {A, B}`）
* **評価タイミング:** あらゆる**発注直前**（初期建て／TP 反転建て直し／SL リエントリ／補充指値）に毎回実行。
* **実ロット:** `actualLot = BaseLot × lotFactor_sys` をブローカーの `LotStep / MinLot / MaxLot` で丸め・クリップ。
* **独立性:** A の決済で更新されるのは **A の DMCMM のみ**、B も同様。

> 参考（MQH 側公開想定）：`init() / winStep() / loseStep() / factor()` 等。**勝敗判定はEA側**で行い、結果に応じて `winStep()` / `loseStep()` を呼ぶ。

## 6) 価格・約定ルール（実TP/実SL）

* **指値の基準:** Buy 系＝Ask 基準／Sell 系＝Bid 基準。
* **TP/SL（実設定）:** エントリ基準で ±d（Ask/Bid は足さない）

  * Long：TP = Entry + d（**判定：Bid ≥**）、SL = Entry − d（**判定：Bid ≤**）
  * Short：TP = Entry − d（**判定：Ask ≤**）、SL = Entry + d（**判定：Ask ≥**）
* **TP 用の影指値は不使用**（サーバ TP のみ）。

## 7) 初期化（方式B・簡易）

* **系統A：** Market で 1 本建て（方向は固定 Buy/Sell 任意。デフォルト Buy）。

  * 建てる直前に `DMCMM(A)` で `actualLot_A` を取得。
  * 約定後、TP/SL=±d を設定。コメント：`MoveCatcher_A`。
* **系統B：** A 建値 ± s に **OCO** を即時配置

  * 上：`SellLimit @ Entry_A + s`、下：`BuyLimit @ Entry_A − s`。
  * **置く直前のみ** `Spread ≤ MaxSpreadPips` を要求。
  * どちらかが約定 → 片割れを即キャンセル。成立直後に `DMCMM(B)` を評価して TP/SL=±d を設定。コメント：`MoveCatcher_B`。
  * 以後、**2本生存中は Pending を持たない**（欠落時のみ補充指値）。

## 8) ランタイム（両系統 A/B 共通）【★修正明記★】

**勝敗判定はEA本体側で行う**（**TP=Win / SL=Loss**）。**判定結果に応じて、該当系統の DMCMM に対し `winStep()` または `loseStep()` を呼び出し**、内部状態（数列・係数）を更新する。

* **TP（実TP）で決済されたら**

  1. **Win を DMCMM(state\_sys) に反映**（`winStep()`）
  2. 最新 `lotFactor_sys` を取得 → `actualLot` 決定
  3. **反対方向**を Market で即時エントリ
  4. 新ポジに TP/SL=±d を設定（実TP/実SL）
  5. コメントは系統ラベル維持（`MoveCatcher_A/B`）

* **SL（実SL）で決済されたら**

  1. **Loss を DMCMM(state\_sys) に反映**（`loseStep()`)
  2. 最新 `lotFactor_sys` を取得 → `actualLot` 決定
  3. **同方向**を Market で即時リエントリ
  4. 新ポジに TP/SL=±d を設定（実TP/実SL）
  5. コメントは系統ラベル維持

* **同時到達（A/B 同バー）:** どちら先でも可。各系統独立なので順序依存は持たない。

* MT4 はイベントフックがないため、**OnTick で履歴差分を検知**して上記を実施（反転が次ティックになることは許容）。

### 勝敗検知（参考実装方針）

* OnTick で **直近クローズ注文**の `ClosePrice` と **設定済み TP/SL** の一致・条件到達で **TP/SLどちらで閉じたかを判別**。
* 追加のロジックは不要（本 Lite では**単純ルール**で十分）。

### Gap Correction（s=d/2 吸着）Lite拡張

* `GapCorrection=ON` のときのみ有効。
* 2本同時保有時の建値間隔 `g` が `s=d/2` から `ε` を超えてズレた状態が `GapDwellSec` 継続すると補正判定。
* 残TP/SL距離が `μ·d` 超かつ `GapCooldownSec` 経過後に発火。
* 現値が目標価格 `P*` を跨いだティックで **MITスナップ**（ズレ側をクローズ→同方向成行で再建）。
* MIT不成立で `GapTimeoutSec` 経過時は指値吸着フォールバック（1本体制に落としてPendingを1本のみ配置）。
* 補正イベントは勝敗集計に含めない（`winStep()/loseStep()` は呼ばない）。

## 9) 欠落時の補充（1 本になったとき）

* 生存側建値 ± s で **欠落側の片側指値を 1 本だけ置く**（OCO ではない）。

  * 生存が Long → 欠落は `SellLimit @ LongEntry + s`
  * 生存が Short → 欠落は `BuyLimit @ ShortEntry − s`
* **置く直前のみ** `Spread ≤ MaxSpreadPips` を要求。
* 約定したら 2 本体制に復帰（以後 Pending は持たない）。
* **補充ロットも発注直前に DMCMM（欠落系統）評価**で決定。

## 10) スプレッド方針（最小）

* **判定する:** “置く”行為のみ（初期Bの OCO／欠落時の補充）。
* **判定しない:** 成行エントリ・リエントリ、TP/SL 設定、Cancel/Close。

## 11) ログ（簡易・推奨）

* `Reason{INIT, OCO_HIT, OCO_CANCEL, TP_REVERSE, SL_REENTRY, REFILL, REBALANCE_SNAP, REBALANCE_LIMIT, REBALANCE_SKIP_NEARGOAL, REBALANCE_SKIP_FREEZE, REBALANCE_SKIP_VOL, REBALANCE_TIMEOUT}`
* `System{A|B}, Entry/SL/TP, actualLot, Spread, Magic, Ticket` に加え、Gap Correction 時は `EntryA/EntryB, g, s, ε, Mode{SNAP|LIMIT}, LotMode{KEEP|RECALC}, P*, TicketClosed, TicketNew, CooldownSec` などを出力。
* `勝敗集計:`TP=Win / SL=Loss / その他=Neutral` の単純ルールで OK。
* `DMCMM デバッグ:** ロット係数と使用シーケンスのスナップショットを発注時に出力。

## 12) 受け入れチェック

* 初期化：A=Market＋TP/SL、B=±s OCO（Spread OK）→ B 成立で片割れキャンセル。
* TP（実TP）後：**EA が Win 判定 → DMCMM へ `winStep()`** → 最新ロットで**逆方向** Market → 新ポジに ±d。
* SL（実SL）後：**EA が Loss 判定 → DMCMM へ `loseStep()`** → 最新ロットで**同方向** Market → 新ポジに ±d。
* 2 本生存中は Pending なし。1 本時のみ補充指値。
* 実ロット = BaseLot × DMCMM 係数を**発注直前**に毎回評価（A/B 独立）。
* Spread 判定は**置くときだけ**。
* 同系統 2 本同時成立／合計 3 本以上は**後着から是正**して 2 本以内へ。
* GapCorrection=ON時、2本同時保有で `|g−s|>ε` が `GapDwellSec` 継続すると MITスナップで誤差が縮小。
* MIT不成立時は `GapTimeoutSec` 経過で指値吸着が実行され、復帰後の `|g−s|` が初回より縮小（またはε以内）。
* 補正イベントは勝敗集計に含まれず、2本同時保有時にPendingを持たない原則を維持。
* Freeze/Stops違反・NearGoal・過大スプレッドでは補正がスキップされログに理由が出る。

## 13) 既知の割り切り

* 同ティック完全反転は保証しない（MT4/実TP・OnTick 検知のため）。**小さなズレは許容**。
* 距離帯・生存同期リセット・MaxLot 等の上級機能は本 **Lite** では未搭載。

---

### 付録A：責務の境界（明文化）

* **EA 本体の責務**

  * 勝敗（TP/SL）判定、再エントリ方向の決定、発注とTP/SL設定、スプレッド判定（置くときのみ）、ログ出力。
* **DMCMM（MQH）の責務**

  * `winStep()` / `loseStep()` に応じた **数列・係数の更新**、`factor()` での **最新ロット係数の提供**。
  * **勝敗を自動判定しない**（EAからの明示呼び出し前提）。

以上。
