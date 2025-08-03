# MoveCatcher for MT4 — README.md

**方式B＋2系統（A/B）・独立運用 EA**
**ロット = BaseLot × DMCMM 係数**／**MaxLot 超過時：当該系統ロット計算を初期化**
**TP 影指値で同ティック反転**／**SL 復帰は価格保護つき成行（推奨）**

---

## 1. 概要

MoveCatcher は、**常時最大2本（系統A/B 別々に 0〜1 本）**を保ち、2本同時保有時の**建値間隔 `s = d/2`**（d は TP/SL 距離）を可能な限り維持する MT4 用 EA です。
**TP 到達時は影指値で即座に逆方向へ反転**し、**SL 到達時は順方向に即復帰**します。
\*\*ロットは DecompositionMonteCarloMM.mqh（DMCMM）\*\*の係数に **BaseLot** を掛けて決定し、**MaxLot 超過時は該当系統のロット計算のみ初期化**して再評価します。

---

## 2. 主な特長

* **等間隔ペア**：2本の建値間隔を目標 `s = d/2`（±ε）で維持
* **TP 同ティック反転**：Long→SellLimit\@Entry+d／Short→BuyLimit\@Entry−d を常時先置き
* **SL 即復帰**：成行＋Slippage で順方向へ復帰（指値待ちの遅延を回避）
* **2系統の独立運用**：A/B でロットと統計を完全分離
* **MaxLot セーフティ**：`BaseLot × 係数` が MaxLot 超なら **その系統の DMCMM 状態を初期化**
* **生存同期リセット**：片系統欠落中に生存系統が決済されるまでに復帰できなければ再初期化
* **スプレッド・距離帯・Tickスナップ**：置く前の品質管理／任意の即時リセット機能

---

## 3. ファイル構成

```
/experts/MoveCatcher.mq4                 ← EA 本体
/include/DecompositionMonteCarloMM.mqh    ← DMCMM（外部／同梱 or 既存）
AGENTS.md                                 ← 実装指示書（仕様）
README.md                                  ← 本ドキュメント
```

> **必須**：`DecompositionMonteCarloMM.mqh` を `include` パスに配置してください（API は本 README 末尾の「依存ライブラリ」参照）。

---

## 4. 動作要件

* MetaTrader 4（最新ビルド推奨）
* ヘッジ口座（**FIFO/ノーヘッジ**口座の場合は機能制限あり）
* 5桁（3桁）ブローカー対応
* 安定した接続とティック供給（反転と SL 復帰の機会損失を避けるため）

---

## 5. インストールと使用方法

1. `MoveCatcher.mq4` を **MQL4/Experts** へ配置
2. `DecompositionMonteCarloMM.mqh` を **MQL4/Include** へ配置（フォルダが無い場合は作成）
3. MT4 を再起動 → ナビゲータの「エキスパートアドバイザ」に表示されることを確認
4. 任意のチャート（推奨：**M1〜M15**）に EA をドラッグ & ドロップ
5. 入力パラメータを設定し「自動売買」をオン
6. 起動直後に **系統A** の成行と **系統B** の `±s` OCO 指値が自動で発注されます（仕様 §7）
7. 停止したい場合は「自動売買」をオフにするか、EA をチャートから外してください

---

## 6. 入力パラメータ

> **精度**：BaseLot/MaxLot は **0.01 刻み**で入力。距離は pips 単位。

| パラメータ               |      型 | 精度 / 例                 | 説明                                                         |
| ------------------- | -----: | ---------------------- | ------------------------------------------------------------ |
| `GridPips`          | double | 例: 100                 | **d**。各ポジの TP/SL 距離（pips）                                  |
| `EpsilonPips`       | double | 例: 1.0                 | 等間隔 s に対する許容幅 ε                                         |
| `MaxSpreadPips`     | double | 例: 2.0                 | **置く前だけ**判定（初期OCO／補充／SL後の Pending 再建て）                 |
| `UseProtectedLimit` |   bool | true/false              | **SL 復帰＝成行＋Slippage**（MT4 標準の価格保護）                           |
| `SlippagePips`      | double | 例: 1.0                 | 成行の最大許容スリッページ（pips）                                      |
| `UseDistanceBand`   |   bool | true/false              | true で発注前に距離帯 `[Min, Max]` をチェック                             |
| `MinDistancePips`   | double | 例: 50                  | 距離帯下限（`UseDistanceBand=true` のとき有効）                            |
| `MaxDistancePips`   | double | 例: 55                  | 距離帯上限（`UseDistanceBand=true` のとき有効）                            |
| `UseTickSnap`       |   bool | true/false              | 2本揃い時に距離逸脱で即初期化（任意）                                      |
| `SnapCooldownBars`  |    int | 例: 2                   | Tickスナップ再発火のクールダウン（バー数）                                 |
| `BaseLot`           | double | 0.01 刻み（例: 0.10）     | **基準ロット**。実ロット = `BaseLot × DMCMM 係数`                         |
| `MaxLot`            | double | 0.01 刻み（例: 1.50）     | **ユーザー上限**。超過時は当該系統のロット計算を初期化して再評価                     |
| `MagicNumber`       |    int | 例: 246810              | EA 識別用マジック                                                   |
**内部派生値**

* `s = GridPips / 2`（ユーザー設定不要）
* `Pip = (Digits==3 || 5 ? 10*Point : Point)`（価格⇄pips 換算）

---

## 7. 取引ロジック（要点）

### 初期化（方式B）

* **系統A**：任意方向で **Market** 建玉（直後に `±d` を設定）。
* **系統B**：A の建値から **±s** に **OCO 指値**を即時設置。どちらかが成立したら片割れをキャンセル。
* すべての注文／ポジションに **コメント**：`MoveCatcher_{System}_{Seq}`（例 `MoveCatcher_A_(0,1)`）。

### TP／SL

* **TP**：影指値（Long→SellLimit\@Entry+d／Short→BuyLimit\@Entry−d）により**同ティック反転**。
* **SL**：**UseProtectedLimit=true** なら **成行＋Slippage** で順方向に即復帰（その後 `±d` を付与）。

### 片系統欠落 → 補充

* 2本→1本になったら、欠落系統を **相手建値 ± s** で補充（Spread/距離帯 OK のとき）。
* **生存同期リセット**：欠落側が**生存系統の決済までに復帰できなければ**全初期化（ただし DMCMM 状態は保持）。

### ロット算出（MaxLot セーフティ）

* 毎発注直前：DMCMM → `lotFactor × BaseLot = lotCandidate`
* `lotCandidate > MaxLot` ⇒ **当該系統の DMCMM 状態のみ初期化** → 再評価 → 上限クリップ
* ブローカーの `MinLot/MaxLot/LotStep` で最終丸め・制限

---

## 8. スプレッド／距離帯／Tickスナップ

* **スプレッド**：**置く前だけ** `Spread ≤ MaxSpreadPips` を要求。Cancel/Close/影の維持には適用しない。
* **距離帯（任意）**：`MinDistancePips ≤ |Pcand − Pother| ≤ MaxDistancePips` を満たすときだけ置く。
* **Tickスナップ（任意）**：2本揃い時、建値差が `[s−ε, s+ε]` を外れ、クールダウン満了で即初期化（DMCMM 状態は保持）。

---

## 9. コメントタグと集計

* フォーマット：`MoveCatcher_{System}_{Seq}`

  * `{System}` = `A` or `B`
  * `{Seq}` = DMCMM の数列（例 `"(0,1)"`）
* **系統判定はコメントで実施**。ログや統計のフィルタキーとして利用してください。

---

## 10. ログ出力（推奨）

各発注・約定・取消・初期化で以下を記録（ファイル or `Print`）：

* `Time, Symbol, System{A|B}, Reason{INIT,REFILL,TP,SL,RESET_ALIVE,RESET_SNAP,LOT_RESET}`
  * `REFILL` = 補充指値・影指値の設置
* `Spread(pips), Dist(pips), GridPips, s, EpsilonPips`
* `lotFactor, BaseLot, MaxLot, actualLot`
* `seqStr, CommentTag, Magic`
* `OrderType, EntryPrice, SL, TP, ErrorCode(if any)`

> **必須**：`LOT_RESET`（MaxLot 超過によるロット計算初期化）発生時は必ずログを残すこと。

---

## 11. バックテスト／最適化のヒント

* **モデル**：Every tick（全ティック）推奨。影指値の同ティック反転と SL 復帰の再現性に影響します。
* **時間足**：M1〜M15（ティック密度の高い環境ほど反応が自然）。
* **スプレッド**：固定値テストよりも「可変スプレッド」のデータが望ましい。
* **パラメータ探索**：`GridPips`、`EpsilonPips`、`MaxSpreadPips`、`BaseLot/MaxLot`、`UseDistanceBand(帯幅)` を中心に。
* **レポート**：`|Entry_A−Entry_B|−s` の分布、リセット発生率、`LOT_RESET` 率、PnL by System(A/B)。

---

## 12. 既知の制約・注意事項

* **MT4 はトレードトランザクションイベント非対応**：OnTick 内で状態差分を監視して処理します。
* **FIFO/ノーヘッジ口座**：同ティック反転や同時 2 ポジが規制される場合あり。**部分決済＋反対新規**等での近似が必要です。
* **StopLevel/FreezeLevel**：サーバ距離制約で SL/TP や指値が拒否される場合は、**距離の丸め**や**次ティック再試行**が必要です。
* **ギャップ／急変**：保護つき成行（Slippage）でもスリップは残ります。ログで観測・調整してください。

---

## 13. 推奨初期設定（例）

* `GridPips=100`, `EpsilonPips=1.0`, `MaxSpreadPips=2.0`
* `UseProtectedLimit=true`, `SlippagePips=1.0`
* `UseDistanceBand=false`（運用で必要なら `Min=50, Max=55` など）
* `UseTickSnap=false`（必要なら `true`, `SnapCooldownBars=2`）
* `BaseLot=0.10`, `MaxLot=1.50`, `MagicNumber=246810`

---

## 14. よくある質問（FAQ）

**Q1. なぜ指値は Buy=Ask 基準／Sell=Bid 基準なの？**
A. 半スプレッドを構造的に吸収し、指定距離（pips）が表示価格の片側に正しく写像されるためです。

**Q2. MaxLot を超えたらどうなる？**
A. **その系統のみ** DMCMM のロット計算状態を**初期化**し、再評価します。最終ロットは `≤ MaxLot` にクリップします（`LOT_RESET` を記録）。

**Q3. 片系統が長く復帰しない場合は？**
A. **生存系統が決済されるまで**復帰を試みます。未復帰なら**全初期化**（DMCMM 状態は保持）。

**Q4. 5桁ブローカーでの pips 計算は？**
A. `Pip = 10*Point` として価格⇄pips を相互変換します（3桁も同様）。4桁/2桁は `Pip = Point`。

---

## 15. 依存ライブラリ（DMCMM）

* 配置手順
  1. `DecompositionMonteCarloMM.mqh` を MT4 の **MQL4/Include** へコピー
  2. EA 冒頭で `#include <DecompositionMonteCarloMM.mqh>` を宣言
* 期待インターフェース（概要）
  * 入力：系統ごとの内部状態 `state_sys`（勝敗系列・連敗・PnL・分散推定・信頼区間など）
  * 出力：`lotFactor_sys`（無次元係数）, `seq_sys`（コメント用数列文字列）
  * **状態初期化 API**：MaxLot 超過時に**当該系統の状態のみ**初期化できること
  * **永続化**：`state_sys` を保存／復元できること（EA 初期化や再起動でも継続）

> 具体的な関数名・構造体はプロジェクト版 DMCMM に合わせてください（本 EA は抽象 I/F に従って呼び出します）。

---

## 16. ライセンス・免責

* 本 EA は教育・研究目的の参考実装です。実運用は自己責任で行ってください。
* マーケット状況／約定仕様／サーバ制約により、意図した動作を確実に保証するものではありません。
* 重大な変更（ブローカー変更・サーバ移行・口座種別変更）前後は必ずデモ検証を行ってください。

---

## 17. 変更履歴（Changelog）

* **v1.0.0** 初版

  * 方式B／2系統独立／TP影反転／SL保護つき成行復帰
  * ロット = BaseLot × DMCMM 係数、**MaxLot 超過で当該系統ロット計算初期化**
  * 生存同期リセット／距離帯／Tickスナップ（任意）

---

## 18. サポート

* 仕様質問・不具合報告・改善提案は Issues へ。
* ログ（`Reason, Spread, Dist, lotFactor, actualLot, seq, System`）の添付があると解析が早まります。
