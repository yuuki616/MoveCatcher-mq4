

---

# MoveCatcher Lite（方式B）EA仕様書

## 1. 概要

* **対象**：MetaTrader 4（MQL4）
* **構成**：2系統（A/B）、各0〜1本、同時最大2本保有
* **基本間隔**：2本同時時の建値間隔 `s = d/2`（d = TP/SL距離）を可能な限り維持
* **決済後の動作**：

  * TP決済 → 逆方向に成行エントリ
  * SL決済 → 同方向に成行エントリ
* **ロット計算**：`実ロット = BaseLot × DMCMM係数`（A/B独立評価）
* **口座前提**：ヘッジ口座（FIFO非対応）

---

## 2. 入力パラメータ

| 名称            | 型      | 例      | 説明                    |
| ------------- | ------ | ------ | --------------------- |
| GridPips      | double | 100    | TP/SL距離（pips）         |
| BaseLot       | double | 0.10   | 実ロット計算の基準値            |
| MaxSpreadPips | double | 2.0    | 指値設置前の最大許容スプレッド（0で無効） |
| MagicNumber   | int    | 246810 | EA識別用                 |

**内部派生値**

* `s = GridPips / 2`
* `Pip = (_Digits==3 || _Digits==5) ? 10*_Point : _Point`

---

## 3. 系統識別

* **コメント**：`MoveCatcher_A` / `MoveCatcher_B`
* すべての注文・ポジションに付与し、系統判定に使用

---

## 4. ロット算出（DMCMM連携）

* 評価タイミング：発注直前（初期建て・反転建て直し・リエントリ・補充指値）
* 実ロット：

  ```
  actualLot = BaseLot × lotFactor_sys
  ```

  ※ブローカーのLotStep/MinLot/MaxLotで丸め
* A/BのDMCMM状態は完全独立に保持・更新

---

## 5. 価格・決済ルール（実TP/実SL）

* 指値基準：

  * Buy系：Ask基準
  * Sell系：Bid基準
* TP/SL設定（実サーバ設定、影指値なし）：

  * Long：TP=Entry+d（Bid判定）、SL=Entry−d（Bid判定）
  * Short：TP=Entry−d（Ask判定）、SL=Entry+d（Ask判定）

---

## 6. 初期化手順（方式B）

1. **系統A**：

   * Marketで1本建て（デフォルトBuy）
   * DMCMM(A)評価→ロット決定
   * TP/SL=±d設定、コメント`MoveCatcher_A`
2. **系統B**：

   * A建値±sにOCO（SellLimit/Buylimit）
   * 置く直前のみSpread判定
   * 約定時に片割れキャンセル→DMCMM(B)評価→TP/SL=±d設定
3. 2本同時保有中はPendingを持たない

---

## 7. ランタイム動作

* **TP決済**：

  * DMCMMでWin反映
  * 最新ロット評価
  * 逆方向にMarketエントリ
  * TP/SL=±d設定（コメント継承）
* **SL決済**：

  * DMCMMでLoss反映
  * 最新ロット評価
  * 同方向にMarketリエントリ
  * TP/SL=±d設定（コメント継承）
* MT4ではOnTickで履歴差分を検知して上記実行

---

## 8. 欠落時の補充

* 保有が1本になったら、生存側建値±sで指値を1本だけ置く

  * Long生存 → SellLimit（建値+s）
  * Short生存 → BuyLimit（建値−s）
* 置く直前のみSpread判定
* 約定で2本体制に復帰

---

## 9. スプレッド判定方針

* 判定する：初期BのOCO設置／欠落時の補充
* 判定しない：成行エントリ、TP/SL設定、Cancel/Close

---

## 10. ログ推奨フォーマット

* **Reason**：INIT / OCO\_HIT / OCO\_CANCEL / TP\_REVERSE / SL\_REENTRY / REFILL
* **System**：A または B
* Entry / SL / TP / actualLot / Spread / Magic / Ticket

---

## 11. 受け入れ条件

* 初期化：A建ち＋TP/SL、BのOCO成立→片割れキャンセル
* TP後：Win反映→逆方向建て直し
* SL後：Loss反映→同方向リエントリ
* 2本時Pendingなし／1本時のみ補充
* Spread判定は置く時だけ
* 同系統2本成立や3本以上は後着から削除し2本以内に是正

---

## 12. 割り切り事項

* 同ティックでの完全反転は保証しない（OnTick検知のため）
* ギャップ補正・距離帯・同期リセット等はLite版では未搭載

---

