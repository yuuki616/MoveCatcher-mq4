

---

# MoveCatcher Lite（MT4 EA）— シンプル仕様書

## 0. 目的（最小要件）

* **同時最大2本**（系統 A/B で各 0〜1 本）。
* 2本同時保有時の**建値間隔**は **s = d/2** を目安に維持。
* **TP 到達で逆方向に即反転**（影指値）、**SL 到達で順方向に即復帰**（成行）。
* **ギャップ補正・距離帯・リセット機能なし**（今回は使わない）。
* **ロットは DMCMM 準拠**：実ロット = **BaseLot ×（DMCMM 係数）**、A/B は**完全独立**に評価。

---

## 1. 用語・派生値

* **d = GridPips**：TP/SL 距離（pips）
* **s = d/2**：2本の目標間隔（pips）
* **Pip**：`(Digits==3 || 5) ? 10*Point : Point`
* **コメント（系統識別）**：`MoveCatcher_A` / `MoveCatcher_B`（※Lite版は数列タグなしで簡略）

---

## 2. 入力パラメータ（最小）

| 名称              | 型      |      例 | 説明                                   |
| --------------- | ------ | -----: | ------------------------------------ |
| `GridPips`      | double |    100 | d。TP/SL 距離（pips）                     |
| `BaseLot`       | double |   0.10 | **DMCMM 係数と掛け算**して実ロットを決定（0.01 刻み推奨） |
| `MaxSpreadPips` | double |    2.0 | **置く前だけ**確認（初期 OCO・補充）。0 で無効         |
| `MagicNumber`   | int    | 246810 | EA 識別                                |

> 追加の細かいパラメータ（slippage 等）は実装側で固定値でも可（最小化のため）。

---

## 3. 価格・約定の基本ルール

* **指値の基準**：Buy 系は Ask 基準、Sell 系は Bid 基準。
* **TP/SL（エントリ基準・Ask/Bidを足さない）**

  * Long：TP = Entry + d（判定：**Bid ≥**）、SL = Entry − d（**Bid ≤**）
  * Short：TP = Entry − d（**Ask ≤**）、SL = Entry + d（**Ask ≥**）
* **TP 反転の影指値（常時先置き）**

  * Long → **SellLimit @ Entry + d**
  * Short → **BuyLimit  @ Entry − d**
    → 到達ティックで**逆方向に即反転**。

---

## 4. DMCMM 連携（ロット決定）

* **インターフェース（抽象）**

  * 入力：`state_A`・`state_B`（各系統の内部状態：勝敗系列ほか）
  * 出力：**lotFactor\_sys**（無次元係数）
* **実ロット**：`actualLot = BaseLot × lotFactor_sys` を **LotStep/Min/Max** で丸め・クリップして発注。
* **独立性**：`state_A` と `state_B` は**完全に別管理**。一方の結果が他方へ混入しない。

> Lite 版では MaxLot・数列タグ・ロット計算リセットの仕組みは**使いません**（最小化）。

---

## 5. 初期化（方式Bの簡易版）

1. **A を Market で 1 本建て**（方向は固定で良い。デフォルト Buy）

   * **DMCMM(A)** を評価 → `actualLot_A` を算出
   * 直後に **TP/SL = ±d**
   * コメント：`MoveCatcher_A`
2. **B のエントリー OCO を即時配置**（A 建値 ±s）

   * 上側：**SellLimit @ Entry\_A + s**
   * 下側：**BuyLimit  @ Entry\_A − s**
   * 置く前に `Spread ≤ MaxSpreadPips` のときのみ送信
   * どちらか成立 → **B 確定**、片割れは**即キャンセル**
   * B 成立時に **DMCMM(B)** を評価 → `actualLot_B`、**TP/SL=±d**、コメント：`MoveCatcher_B`

---

## 6. ランタイム（運用の最小ルール）

### 6.1 TP（利確）

* 影指値が**同ティック**で約定し、**同系統の逆方向**へ自動反転。
* 反転直後に **TP/SL=±d** を再付与（影指値も新 Entry ± d で再セット）。

### 6.2 SL（損切）

* **同方向に Market で即再エントリ**（`actualLot_sys` は再度 DMCMM(sys) で算出）。
* 再エントリ直後に **TP/SL=±d**、影指値再セット。

### 6.3 片系統のみになったら（補充）

* **常に 1 本だけ**を検知したら、相手建値 ± s に**1 本だけ指値を置く**。
* 置く前に `Spread ≤ MaxSpreadPips` を満たさない場合は**スキップ**（次ティックで再試行）。
* **リセットはしない**（未約定でも放置で OK。シンプル優先）。

---

## 7. スプレッド方針（最小）

* **判定する**：**新規で“置く”時のみ**（初期 OCO・補充）。
* **判定しない**：Cancel／Close／影指値の維持／Market 再エントリ。

---

## 8. 異常系（最小の是正のみ）

* **同系統で 2 本同時成立**（レース）：**後着を即クローズ**。
* **合計 3 本以上**：**最後に成立した重複分**からクローズして**2 本以内**へ戻す。
* **StopLevel/FreezeLevel** に抵触する SL/TP・指値は**距離を丸め**るか**次ティックで再試行**。

---

## 9. ログ（任意・簡易）

* `Reason{INIT, OCO_HIT, OCO_CANCEL, TP_REV, SL_REENTRY, REFILL}`,
  `Entry, SL, TP, Spread, System(A/B), actualLot` を `Print`。
* 勝敗集計をするなら：**TP=Win／SL=Loss／その他=Neutral**（ε 判定は任意）。

---

## 10. 受け入れチェック

* [ ] A 初期 Market＋TP/SL、B の **±s OCO** が置かれる
* [ ] OCO 片側成立で片割れが**確実にキャンセル**される
* [ ] **TP 反転**は影指値で即切替、**新ポジに ±d** が付与される
* [ ] **SL 再エントリ**は Market 即時、**新ポジに ±d** が付与される
* [ ] **1 本状態**で相手建値 ± s に**補充指値**が置かれる（Spread 条件 OK 時）
* [ ] Spread 判定は**置くときだけ**
* [ ] **実ロット = BaseLot ×（DMCMM 係数）** が A/B **独立**で機能する

---


