# AGENTS.md — MT4 EA 実装指示書

**Project**: MoveCatcher (方式B＋2系統A/B・独立運用)
**Target Platform**: MetaTrader 4（MQL4）

---

## 1) 目的 / ミッション

* **常時最大2本**（系統A/Bで各0〜1本）を保ち、2本あるときの\*\*建値間隔 s = d/2（±ε）\*\*を可能な限り維持する。
* **TPで逆方向へ同ティック反転**（影指値で実現）、**SLで順方向に即時復帰**する。
* **片系統が欠落**しても、**もう一方（生存系統）が決済されるまで**欠落側の復帰を試行。未復帰なら**初期化**。
* **ロットは DecompositionMonteCarloMM.mqh（以降 DMCMM）**に準拠：
  実ロット = **BaseLot ×（DMCMM算出係数）**。A/B の計算は**完全独立**。
  実ロットが **MaxLot** を超えた場合、**該当系統のロット計算状態のみ初期化**して再評価。

---

## 2) 実行環境 / 制約

* **MT4 / MQL4**。イベントは主に `OnInit / OnTick / OnDeinit` を使用（`OnTradeTransaction` は MT4 非対応）。
* **成行の価格保護**は **Slippage** で行う（MT4標準）。
* **ヘッジ口座**前提。FIFO/ノーヘッジの場合は「部分決済＋反対新規」で近似（別実装ガード要）。
* **StopLevel / FreezeLevel** に注意。サーバ距離制約に抵触する置き値・SL/TP は丸めるか次ティックで再試行。

---

## 3) 入力パラメータ（Inputs）

> **精度**の明示があるものは UI でバリデーションすること（0.01 刻みなど）。

| 名称                  | 型          | 精度 / 例              | 説明                                            |
| ------------------- | ---------- | ------------------- | --------------------------------------------- |
| `GridPips`          | double     | 例: 100              | **d**。TP/SL 距離（pips）                          |
| `EpsilonPips`       | double     | 例: 1.0              | 等間隔 s に対する許容幅 ε（pips）                         |
| `MaxSpreadPips`     | double     | 例: 2.0              | \*\*新規で“置く”\*\*時のみ判定（初期OCO・補充・SL後のPending再建て） |
| `UseProtectedLimit` | bool       | true/false          | SL直後は **成行＋Slippage** で即復帰（価格保護）              |
| `SlippagePips`      | double     | 例: 1.0              | 成行時の最大許容スリッページ（pips）                          |
| `UseDistanceBand`   | bool       | true/false          | 発注前に距離帯でフィルタ                                  |
| `MinDistancePips`   | double     | 例: 50               | 距離帯下限（pips）                                   |
| `MaxDistancePips`   | double     | 例: 55               | 距離帯上限（pips）                                   |
| `UseTickSnap`       | bool       | true/false          | 2本揃い時、間隔逸脱で即初期化（任意）                           |
| `SnapCooldownBars`  | int        | 例: 2                | Tickスナップ再発火のクールダウン（バー数）                       |
| **`BaseLot`**       | **double** | **0.01 刻み（例 0.10）** | **基準ロット**：実ロット = BaseLot ×（DMCMM係数）           |
| **`MaxLot`**        | **double** | **0.01 刻み（例 1.50）** | **ユーザー上限**。実ロットが超過したら**該当系統のロット計算を初期化**       |
| `MagicNumber`       | int        | 例: 246810           | EA管理識別用                                       |

**派生値（内部）**

* `s = GridPips / 2`（ユーザー設定不要、内部で常時算出）
* `Pip = (_Digits==3 || _Digits==5) ? 10*_Point : _Point`（価格⇄pips 換算）

---

## 4) コメント／ラベリング規約（必須）

* **形式**：`MoveCatcher_{System}_{Seq}`

  * `{System}` ∈ `{A,B}`
  * `{Seq}`：**DMCMM** が返す**数列**文字列（例 `"(0,1)"`）
* **全ての注文・ポジション**にこのコメントを付与。
* **系統識別はコメントで行う**（Magic は EA 識別）。

---

## 5) DMCMM 連携・ロット算出規約

* **DMCMM I/F（抽象）**

  * 入力：`state_sys`（系統ごとの内部状態：勝敗系列・連敗・PnL・分散推定・信頼区間 等）
  * 出力：`lotFactor_sys`（無次元係数）／`seq_sys`（コメント用数列文字列）
* **実ロット算出（各発注直前に必ず実行）**

  1. `lotFactor_sys, seq_sys = DMCMM(state_sys)`
  2. `lotCandidate = BaseLot * lotFactor_sys`
  3. **MaxLot 判定**：

     * `lotCandidate > MaxLot` の場合：

       * **当該系統の DMCMM 状態のみ初期化**（他系統には影響しない）。
       * 直後に再評価 → `lotFactor’ , seq’`／`lotCandidate’ = BaseLot * lotFactor’`
       * `lotActual = min(lotCandidate’, MaxLot)` を **LotStep/Min/Max** で丸め・クリップ
       * **イベント名 `LOT_RESET` をログ**
     * それ以外：`lotActual = lotCandidate` を **LotStep/Min/Max** で丸め・クリップ
  4. 注文・ポジに **コメント `MoveCatcher_{System}_{seq}`** を必ず付与
* **勝敗判定**：TP または SL で決済された場合のみ `state_sys.OnTrade(win)` を呼ぶ。その他理由のクローズは勝敗系列に含めない。
* **独立性**：`state_A` と `state_B` は厳密に分離。**戦略初期化・Tickスナップ**が発動しても保持（**例外**：MaxLot超過時に**該当系統のみ**初期化）。

---

## 6) 価格・約定ポリシー（MT4 準拠）

* **指値の基準**：**Buy系＝Ask 基準**／**Sell系＝Bid 基準**
* **TP/SL の設定**（Ask/Bid を足さない・エントリ基準）：

  * Long：TP = Entry + d（判定：**Bid ≥**）、SL = Entry − d（**Bid ≤**）
  * Short：TP = Entry − d（**Ask ≤**）、SL = Entry + d（**Ask ≥**）
* **TP反転用 影指値（常時先置き）**：

  * Long → **SellLimit @ Entry + d**
  * Short → **BuyLimit  @ Entry − d**
    → **TP判定価格とトリガ価格が一致**し、**同ティック反転**となる。
* **SL復帰（UseProtectedLimit=true）**：**成行＋Slippage** で即復帰（順方向）。復帰後に **TP/SL=±d** を即付与。

---

## 7) 初期化フロー（方式B）

* **Step A**：任意方向で **Market** 1本（系統A）。直後に **TP/SL=±d**。ロットは §5 手順、コメントは `MoveCatcher_A_{seq}`。
* **Step B**：A の建値を基準に **±s の OCO** を即時設置（系統B候補）。

  * 上側：SellLimit @ Entry\_A + s
  * 下側：BuyLimit  @ Entry\_A − s
  * OCO のロット・コメントは **系統Bとして §5 手順**で決定・付与。
* **OCO 片割れキャンセル**：B が成立したら片割れ Pending を即削除。B 成立ポジにも **TP/SL=±d** を付与。
* **Spread 判定**：**“置く”行為**（OCO・補充・Pending再建て）にのみ `MaxSpreadPips` を適用。

---

## 8) ランタイム挙動（イベント処理の設計原則）

> MT4 では専用のトレードイベントがないため、**OnTick でポジション／注文の差分監視**を行い、成立／決済の判定・処理を行う。

### 8.1 保有本数の遷移（2本↔1本↔0本）

* **2本保有（A/B とも）**：`AliveSystem=None, MissingSystem=None, MissingRecovered=true`
* **1本保有へ遷移**：残存ポジのコメントから `AliveSystem` を特定、`MissingSystem = other(AliveSystem)`、`MissingRecovered=false`
* **0本**：直ちに **初期化フロー（方式B）** を実行

### 8.2 欠落系統の補充

* 条件：**1本保有**かつ **Spread ≤ MaxSpreadPips**
* 置き値：**相手建値 ± s**

  * 相手が Long → SellLimit @ LongEntry + s
  * 相手が Short → BuyLimit  @ ShortEntry − s
* 距離帯：`UseDistanceBand==true` のときのみ `MinDistancePips ≤ |Pcand−Pother| ≤ MaxDistancePips` を要求
* ロット・コメント：発注直前に §5 手順を適用
* **約定したら**：`MissingRecovered=true`、`AliveSystem=None, MissingSystem=None`（2本へ復帰）

### 8.3 TP（利確）と影指値

* 影指値で **同ティック反転**。新ポジに **TP/SL=±d** を即付与。
* 反転時のロット・コメントは **毎回 §5 手順で再評価**。

### 8.4 SL（損切）と復帰

* **UseProtectedLimit=true**：**成行＋Slippage**で即復帰。
* **UseProtectedLimit=false**：成行（slippage 任意）で即復帰。
* 復帰のたびに **§5 手順**（MaxLot 監視含む）を適用し、**コメント を更新**。

### 8.5 生存同期リセット（タイムアウト不使用）

* 欠落系統がいる間（`AliveSystem≠None && MissingRecovered=false`）に、
  **生存系統のポジションが決済**された**時点までに**欠落側が復帰していなければ、
  → **EA 管理分を全クローズ／全 Pending 削除 → 初期化フロー（方式B）**。
* **保持**：この初期化でも **DMCMM の `state_A/B`・Tickスナップ・距離帯の内部状態は保持**（**MaxLot超過**による**当該系統のロット計算初期化**のみ例外）。
* **同時ティックの優先順位**：**復帰約定 ≻ 生存決済**（復帰を優先し、初期化を回避）。

### 8.6 Tickスナップ（任意）

* 有効時、**2本揃い**の局面で**建値差 Dist** を監視。
  `Dist ∉ [s−ε, s+ε]` かつクールダウン満了 → **全クローズ／全 Pending 削除 → 初期化フロー（方式B）**。
* この初期化でも **DMCMM の `state_A/B` は保持**（MaxLot超過時初期化のみ例外）。

---

## 9) スプレッド方針（厳守ルール）

* **判定する**：\*\*新規で“置く”\*\*とき（初期 OCO、補充指値、SL 後に Pending を使う場合）
* **判定しない**：Cancel／Close／影指値の維持／成行（保護つき）
  → 2本維持と安全弁を優先。

---

## 10) 例外・是正・ブローカー制約

* **同系統で同時に2本成立（レース）**：**後着を即クローズ**し、「各系統同時 1 本」を維持。
* **合計3本以上**：**最終成立の重複系統分**から順にクローズして是正。
* **StopLevel / FreezeLevel**：距離不足が発生した SL/TP・指値は丸め or 次ティック再試行。
* **ロット**：

  * ブローカーの `MinLot / MaxLot / LotStep` を**最終的に必ず適用**。
  * **ユーザー `MaxLot`** を超えた場合は **該当系統の DMCMM を初期化→再評価**。そのうえで**上限クリップ**。
* **永続化**：`state_A / state_B` は `GlobalVariable` またはファイルで**保存・復元**。

---

## 11) テレメトリ / ログ（必須）

各発注・約定・取消・初期化のタイミングで、**1 レコード**を出力：

* **Fields**:

  * `Time`, `Symbol`, `System{A|B}`, `Reason{INIT, REFILL, TP, SL, RESET_ALIVE, RESET_SNAP, LOT_RESET}`,
  * `Spread(pips)`, `Dist(pips)`, `GridPips`, `s`,
  * `lotFactor`, `BaseLot`, `MaxLot`, `actualLot`,
  * `seqStr`, `CommentTag`, `Magic`,
  * `OrderType`, `EntryPrice`, `SL`, `TP`, `ErrorCode(if any)`
* **要件**：コメントタグで**系統別**集計が可能なこと。`LOT_RESET` は**必ず**記録。

---

## 12) 受け入れ基準 / QA チェックリスト

* [ ] **Pip 換算**が銘柄仕様に一致する（5桁/3桁でも正しく動作）。
* [ ] **実ロット**＝ `BaseLot × lotFactor` に **LotStep/Min/Max** を適用。
* [ ] **MaxLot 超過**で **当該系統の DMCMM 状態が初期化→再評価**され、最終ロットが `≤ MaxLot`。ログに `LOT_RESET`。
* [ ] **初期化フロー（方式B）**：A=Market＋TP/SL、B=±s の OCO、B 成立で片割れ即削除。
* [ ] **TP 反転**：影指値で同ティック反転、反転後に **TP/SL=±d** 付与。
* [ ] **SL 復帰**：`UseProtectedLimit=true` で成行＋Slippageの即復帰。
* [ ] **補充**：相手建値±s、Spread/距離帯フィルタ適用時は満たした場合のみ発注。
* [ ] **勝敗集計**：`TP` または `SL` で決済された注文のみ `state_sys.OnTrade` が呼ばれる。
* [ ] **生存同期リセット**：生存決済時点までに未復帰なら全初期化（DMCMM 状態は保持）。
* [ ] **Tickスナップ（任意）**：距離逸脱＋クールダウンで即初期化（DMCMM 状態保持）。
* [ ] **全注文・全ポジ**に `MoveCatcher_{System}_{Seq}` コメント付与。
* [ ] **同系統 2 本同時成立／合計 3 本**を**自動是正**。
* [ ] すべての**Spread 判定**は「置くとき」のみ。Cancel/Close/影は無条件。

---

## 13) 納品物 / 構成

* `MoveCatcher.mq4`（EA 本体）

  * 入力パラメータ定義（§3）
  * Pip 換算ユーティリティ／ロット丸め・クリップ
  * コメントタグ生成・解析
  * 状態管理（Alive/Missing/MissingRecovered、state\_A/B 永続化）
  * 初期化フロー／OCO 制御／影指値運用
  * DMCMM 呼び出し（lotFactor・seq の取得）／MaxLot 超過時の **当該系統ロット計算初期化**
  * Spread/距離帯/スナップ/生存同期リセット
  * ロギング
* `DecompositionMonteCarloMM.mqh`（外部提供）

  * `state_sys` 構造体・保存/復元
  * `DMCMM(state_sys)->(lotFactor, seq)` の提供
  * **状態初期化 API**（MaxLot 超過時に呼び出す）
* `README.md`（セットアップ手順、推奨パラメータ例、既知の制約）

---

## 14) 設定例（推奨初期値）

* `GridPips=100`, `EpsilonPips=1.0`, `MaxSpreadPips=2.0`
* `UseProtectedLimit=true`, `SlippagePips=1.0`
* `UseDistanceBand=false`（※必要に応じて `50–55` 等に設定）
* `UseTickSnap=false`（※必要に応じて `true`／`SnapCooldownBars=2`）
* `BaseLot=0.10`, `MaxLot=1.50`, `MagicNumber=246810`

---

### 実装上の注意（再掲）

* **擬似コード禁止**：本書は**要件・手順のみ**を記述。実装は MQL4 の関数群で直接行うこと。
* **同時イベントの優先順位**：欠落側の復帰約定を**優先**して初期化を回避（復帰≻決済）。
* **丸め・クリップ**：ブローカー `LotStep/Min/Max` の適用を**最終段階**で必ず行う。
* **状態の寿命**：戦略の再初期化・スナップ初期化でも **DMCMM 状態は保持**（MaxLot 超過時のみ該当系統を初期化）。

---

本 AGENTS.md をそのまま **Codex 用の実装指示**として渡してください。
不明点（DMCMM の I/F 具体名、state のシリアライズ仕様など）は、別紙技術設計書で補足します。
