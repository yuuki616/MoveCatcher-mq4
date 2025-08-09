# MoveCatcher Lite for MT4 — README.md

**最小構成の2ポジ・グリッドEA（方式B）**
**ロット = BaseLot × DMCMM係数（A/B 完全独立）**
**TPは影指値で同ティック反転 / SLは成行で順方向リエントリ**
**ギャップ補正・リセット・距離帯：不使用（超シンプル版）**

---

## 1. なにができる？

* 常時 **最大2本（A/Bで各0〜1本）** を維持しやすい超シンプル運用。
* 2本そろったときの建値間隔を **s = d/2**（d=TP/SL距離）に寄せる。
* **TPで逆方向に即反転**（影指値先置き）、**SLで順方向に即再エントリ**（成行）。
* ロットは **DecompositionMonteCarloMM.mqh（DMCMM）** の係数に **BaseLot** を掛け算（A/Bは完全独立）。

> 本版は検証用の**最小ロジック**です。ギャップ補正や各種リセット・距離帯フィルタは入れていません。

---

## 2. ファイル構成

```
/MQL4/Experts/MoveCatcherLite.mq4      ← EA本体
/MQL4/Include/DecompositionMonteCarloMM.mqh  ← DMCMM（外部 or 同梱）
README.md
```

---

## 3. 動作環境

* MetaTrader 4（最新ビルド推奨）
* ヘッジ口座を想定（FIFO/ノーヘッジは制約あり）
* 5桁/3桁ブローカー対応（Pip=10\*Point を考慮）

---

## 4. パラメータ（最小）

| パラメータ           |      型 |      例 | 説明                                     |
| --------------- | -----: | -----: | -------------------------------------- |
| `GridPips`      | double |    100 | d。各ポジのTP/SL距離（pips）                    |
| `BaseLot`       | double |   0.10 | **実ロット = BaseLot × DMCMM係数**（0.01刻み推奨） |
| `MaxSpreadPips` | double |    2.0 | **置く前だけ**チェック（初期OCO・補充）。0で無効           |
| `MagicNumber`   |    int | 246810 | EA識別用                                  |

**内部派生値**

* `s = GridPips / 2`
* `Pip = (_Digits==3 || _Digits==5) ? 10*_Point : _Point`

---

## 5. ロット算出（DMCMM 準拠）

* DMCMMは **A/B 系統ごとに独立**評価：
  `actualLot_sys = BaseLot × lotFactor_sys` → ブローカーの `LotStep/Min/Max` で丸め・クリップ。
* 本Lite版では **MaxLot やロット計算のリセット機構は使いません**（純粋に掛け算のみ）。

> 期待I/F（概要）：`(lotFactor_sys) = DMCMM(state_sys)`
> `state_A` と `state_B` は混ぜないでください（勝敗系列などは各系統で独立管理）。

---

## 6. 価格ルール（MT4準拠）

* 指値の基準：**Buy系=Ask基準 / Sell系=Bid基準**。
* TP/SL（エントリ基準・Ask/Bidは足さない）：

  * **Long**：TP=Entry+ d（判定：Bid ≥）、SL=Entry − d（Bid ≤）
  * **Short**：TP=Entry − d（判定：Ask ≤）、SL=Entry + d（Ask ≥）
* **TP反転の影指値（常時先置き）**

  * Long → SellLimit @ Entry + d
  * Short → BuyLimit  @ Entry − d
    → 到達ティックで**同ティック反転**。

---

## 7. エントリーと運用フロー（Lite）

### 初期化（方式Bの簡易版）

1. **系統A：Marketで1本**（デフォルトはBuyでもSellでも可）

   * DMCMM(A)でロット決定 → **TP/SL=±d** を付与 → コメント：`MoveCatcher_A`
2. **系統B：A建値±sでOCO**

   * 上側 SellLimit / 下側 BuyLimit を同時設置（**置く前に Spread チェック**）
   * どちらか成立で B 確定、**片割れは即キャンセル** → **TP/SL=±d** 付与 → コメント：`MoveCatcher_B`

### 運用中の挙動

* **TP**：影指値が同ティック約定→**逆方向に即反転**→新ポジに**TP/SL=±d**再付与。
* **SL**：**成行**で**順方向に即リエントリ**→新ポジに**TP/SL=±d**再付与。
* **片系統のみ**になったら：**相手建値±s** に**1本だけ補充指値**（Spread OK のとき）。
  リセットやタイムアウトは**しません**（未約定ならそのまま放置でOK）。

---

## 8. コメント（系統識別）

* 簡略フォーマット：`MoveCatcher_A` / `MoveCatcher_B`
  ※Lite版は数列タグなどの追加情報は付けません（必要になったら拡張）。

---

## 9. スプレッド方針（最小）

* **判定する**：\*\*新規で“置く”\*\*ときのみ（初期OCO・補充）。
* **判定しない**：Cancel / Close / 影指値の維持 / 成行リエントリ。

---

## 10. 既知の割り切り

* **ギャップ補正なし**（スリッページ・ギャップ時はズレが起こり得ます）
* **各種リセット（生存同期・距離帯・Tickスナップ）なし**
* **保護付きリミット/細かいslippage制御なし**（SL復帰は単純に成行）
* **勝敗カウント**をするなら：**TP=Win / SL=Loss / その他=Neutral** の単純ルールでOK（ε判定は実装任せ）

---

## 11. インストール & 使い方

1. `MoveCatcherLite.mq4` を **MQL4/Experts** に、`DecompositionMonteCarloMM.mqh` を **MQL4/Include** に配置
2. MT4を再起動 → 任意チャート（M1〜M15推奨）へEAを適用
3. `GridPips / BaseLot / MaxSpreadPips / MagicNumber` を設定
4. 自動売買をON → 稼働

**推奨初期値**：
`GridPips=100`, `BaseLot=0.10`, `MaxSpreadPips=2.0`, `MagicNumber=246810`

---

## 12. ログ（簡易）

`Print`等で以下の最低限を出してください：
`Reason{INIT,OCO_HIT,OCO_CANCEL,TP_REV,SL_REENTRY,REFILL}, Entry, SL, TP, Spread, System(A/B), actualLot`

---

## 13. 受け入れチェック

* [ ] A 初期 Market＋TP/SL → B の **±s OCO** が置かれる
* [ ] OCO 片側成立で**片割れキャンセル**が必ず起こる
* [ ] **TP 反転**が影指値で同ティックに切り替わり、**新ポジに±d**が付く
* [ ] **SL リエントリ**が成行で即時行われ、**新ポジに±d**が付く
* [ ] **1本状態**で相手建値±sに**補充指値**が出る（Spread OK時）
* [ ] Spread 判定は**置くときだけ**
* [ ] **実ロット = BaseLot ×（DMCMM係数）** が **A/B独立**で反映される

---

---
