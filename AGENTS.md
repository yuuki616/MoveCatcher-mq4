# AGENTS.md — MT4 EA 追加仕様書（Ultimate-Lite Strict 最小実装）

**Project:** MoveCatcher Lite Strict（A/B 系統・最大2本）
**Target:** MetaTrader 4（MQL4）
**方針:** Pending/OCO を一切使用せず、2本目は相手建値±s に触れた瞬間のみ成行（疑似MIT）で建てる。補充は勝敗外（Neutral）で DMCMM は発注時に評価。A/B ロット計算を独立／共通で切り替え可能。

---

## 入力パラメータ（7つ）

| 名称 | 型 | 例 | 説明 |
| --- | ---: | ---: | --- |
| GridPips | double | 100 | d。TP/SL距離（pips） |
| TpOffsetPips | double | 1.0 | TP距離への加算値（pips） |
| BaseLot | double | 0.10 | 実ロット = BaseLot × 係数 |
| MaxSpreadPips | double | 2.0 | 置く前のスプレッド上限（補充時にも流用） |
| MagicNumber | int | 246810 | EA識別 |
| **UseSharedDMCMM** | bool | **false** | **false**=A/B独立、**true**=A/B共通（係数・勝敗シーケンスを共有） |
| LogMode | ENUM | FULL | ログレベル（**FULL**=詳細ログ、**MIN**=最小限） |

> 既定は従来どおり **独立(false)**。運用途中での切替は非推奨（切替時は EA 再起動・状態初期化を前提）。

---

## 内部定義（固定/派生）

* `Pip = (_Digits==3||5) ? 10*_Point : _Point`
* `d = GridPips * Pip`、`o = TpOffsetPips * Pip`
* `s = d/2`
* TP距離：`d + o`、SL距離：`d`
* 閾値ε（固定定数）：`EPS_PIPS = 0.3`
  * `EpsilonPoints = round(EPS_PIPS * Pip / _Point)` → `OrderSend.deviation` に使用
* スプレッド上限：`SpreadCapPips = MaxSpreadPips`

---

## DMCMM のモード別挙動

### UseSharedDMCMM = false（独立・既定）

* インスタンス：`DMCMM_A` / `DMCMM_B` を別々に保持。
* 勝敗更新：A の TP/SL→A のみ `winStep/loseStep`、B も同様。
* ロット算出：発注直前に `factor(A/B)` を取得。

### UseSharedDMCMM = true（共通）

* インスタンス：`DMCMM_SHARED` を 1 つだけ保持（A/B 共用）。
* 勝敗更新：A/B いずれかが TP/SL で閉じたら共通 `winStep/loseStep`。
  * 同一ティックで A/B 両方閉じたら、クローズ時刻→チケット番号順に逐次 2 回更新。
* ロット算出：発注直前に共通 `factor()` を取得（A/B とも同一係数）。

> 補充は Neutral：どちらのモードでも `winStep/loseStep` は呼ばない。補充のロットは、その瞬間の該当係数（独立なら欠落系統の `factor()`／共通なら `factor()`）で算出。

---

## 取引ライフサイクル（Ultra-Lite Strict）

### 初期化

1. **A を成行で 1 本** → **SL=±d, TP=±(d+o)** 設定（`MoveCatcher_A`）。
2. **B は置かない**（監視開始のみ）。

### TP/SL 決済

* **TP（Win）**：EA が Win 判定→（独立なら該当系統／共通なら共通）`winStep()`→**反転エントリを監視**：生存側建値 `entryAlive` ± `s` に触れたティックのみ成行→**SL=±d, TP=±(d+o)**。
* **SL（Loss）**：同様に `loseStep()`→**順方向エントリを監視**：生存側建値 `entryAlive` ± `s` に触れたティックのみ成行→**SL=±d, TP=±(d+o)**。
* ロットは毎回「発注直前」に `BaseLot×係数` を丸め/クリップ。監視中にスプレッド上限を超えるティックでは発注しない。

### 欠落補充（疑似MIT／Pendingなし）

* 状態が 1 本のときだけ監視・発注。
* アンカー = 生存側の建値 `entryAlive`、目標 `P*`：
  * 生存 Long → **Sell @ `entryAlive + s`**
  * 生存 Short → **Buy  @ `entryAlive − s`**
* 発注条件（そのティックのみ）
  * **Sell 補充**：`|Bid − P*| ≤ 0.3pips` かつ `Spread ≤ MaxSpreadPips`
  * **Buy 補充** ：`|Ask − P*| ≤ 0.3pips` かつ `Spread ≤ MaxSpreadPips`
* 執行
  * `OrderSend(OP_SELL/BUY, ..., deviation=EpsilonPoints)`（`P*±ε` 超過は拒否）
  * Filled→**SL=±d, TP=±(d+o)** 設定、コメント `MoveCatcher_B`（または欠落側ラベル）。
  * 拒否/条件未充足→何もしない（監視継続）。
* DMCMM：Neutral（勝敗更新なし）。ロットは発注直前に（独立/共通の）`factor()` で決定。

### 監視中のアンカー更新

* 生存側が TP/SL で建て直されたら、新建値を即アンカーにして `P*` 再計算（監視再アーム）。

### サニティ整流

* 同系統 2 本/合計 3 本以上になったら、後着から即クローズ（`SANITY_TRIM`）で最大 2 本に収束。

---

## ログ（モード表示を追加）

* `LogMode=FULL`：既存ログをすべて出力。
* `LogMode=MIN` ：`Log()` レベルの詳細ログを抑制し、必要最小限のみ出力。
* 既存：`INIT, TP_REVERSE, SL_REENTRY, SANITY_TRIM`
* 補充：`REFILL_STRICT_ARM`（監視開始）, `REFILL_STRICT_HIT`（約定）, `REFILL_STRICT_SKIP_SPREAD`, `REFILL_STRICT_REQUOTE/REJECT`
* モード注記：各ログに `LotMode={INDEPENDENT|SHARED}` を付与（係数の意味づけを明確化）。

---

## 受け入れチェック

1. 補充は常に疑似MIT＆Pendingなし。`|Bid/Ask−P*|≤0.3pips` かつ `Spread≤MaxSpreadPips` のティックのみ約定。
2. TP/SL 時のみ勝敗更新：
   * 独立：該当系統の DMCMM だけ更新。
   * 共通：共通 DMCMM を更新（同ティック 2 件は順序規則で逐次実行）。
3. ロット算出は発注直前評価：
   * 独立：`BaseLot×factor(A/B)`
   * 共通：`BaseLot×factor(shared)`
4. 補充は Neutral（`winStep/loseStep` 不呼出）。
5. 最大 2 本厳守（異常時は `SANITY_TRIM`）。
6. 監視中のアンカー再建で即 `P*` 再計算・監視継続。

---

## 実装メモ（DMCMM 呼び分けの最小コードイメージ）

```text
double LotFactor(string sys) {
  return UseSharedDMCMM ? DMCMM_SHARED.factor() : DMCMM_sys[sys].factor();
}
void WinStep(string sys) {
  if (UseSharedDMCMM) DMCMM_SHARED.winStep();
  else                DMCMM_sys[sys].winStep();
}
void LoseStep(string sys) {
  if (UseSharedDMCMM) DMCMM_SHARED.loseStep();
  else                DMCMM_sys[sys].loseStep();
}
```

> **注意**：`UseSharedDMCMM` の変更は運用中に切替えないこと（係数シーケンスの一貫性が崩れるため）。切替える場合は EA 再起動で DMCMM 状態を意図どおり初期化すること。

