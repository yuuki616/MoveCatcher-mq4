//+------------------------------------------------------------------+
//|                                                  MoveCatcher.mq4 |
//| A/B二系統（方式B・修正版/Lite, 実TP/実SL）                      |
//|  - A: 成行エントリ（TP=反転 / SL=順方向で即時再エントリ）      |
//|  - B: 初期はA建値±sにOCOで指値、成立後は片脚キャンセル          |
//|       決済後はAと同様に成行で即時リエントリ                     |
//|  - 欠落時の補充：片側指値を1本だけ（OCO禁止）                   |
//|  - Spread判定は「置く時のみ」。0で無効                          |
//|  - 実ロット = BaseLot × DMCMM係数（発注直前に毎回評価）         |
//|  - A/BのDMCMM状態は完全独立                                     |
//|  - 勝敗判定はEA本体が行い、DMCMMへ winStep()/loseStep() で反映 |
//|  - 2本生存中はPendingなし。3本以上は後着から是正して2本以内へ    |
//+------------------------------------------------------------------+
#property strict

// ====== Includes ======
#include "DecompositionMonteCarloMM.mqh"

// ====== Inputs ======
input double   InpGridPips       = 100;     // d: TP/SL 距離（pips）
input double   InpBaseLot        = 0.01;    // BaseLot
input double   InpMaxSpreadPips  = 2.0;     // 置く時の最大スプレッド[pips]（0で無効）
input int      InpMagic          = 246810;  // マジック
input int      InpSlippagePoints = 10;      // 許容スリッページ[point]
input bool     InpStartOnLaunch  = true;    // 起動直後にAを建てる（成行）
input int      InpStartDir       = 1;       // Aの初回方向: 1=BUY, -1=SELL
input int      InpReasonTolPoints= 10;      // TP/SL判定許容[point]
input bool     InpVerboseLog     = true;    // 詳細ログ

// --- Gap Correction Params ---
input bool     InpGapCorrection  = false;   // ギャップ補正を有効化
input double   InpGapEpsilonPips = 0.3;     // 許容誤差ε[pips]
input int      InpGapDwellSec    = 3;       // 誤差継続秒数
input int      InpGapCooldownSec = 30;      // 補正後の待機秒
input int      InpGapTimeoutSec  = 30;      // MIT待ちタイムアウト
input double   InpNearGoalRatio  = 0.2;     // μ: TP/SLまでの残距離比
input double   InpSpreadCorrPips = 0.0;     // 補正時の最大スプレッド許容[pips]
enum ENUM_RB_LOT_MODE { RB_KEEP, RB_RECALC };
input ENUM_RB_LOT_MODE InpRebalanceLotMode = RB_KEEP; // ロット維持/再評価

// ====== Helpers ======
double PIP(void){ return (Digits==3 || Digits==5) ? (10.0*Point) : Point; }
double Pip2Pt(double pips){ return pips * PIP(); }
double RoundPrice(double price){ return NormalizeDouble(price, Digits); }
bool   Almost(double a,double b,double tolPts){ return MathAbs(a-b) <= tolPts*Point; }

string TF(){ return EnumToString((ENUM_TIMEFRAMES)Period()); }
void Log(string msg){ if(InpVerboseLog) Print(Symbol(),",",TF(),": ",msg); }
void LogAlways(string msg){ Print(Symbol(),",",TF(),": ",msg); }

// ====== DMCMM Wrapper（数列ログ取得可） ======
class CDMCMM {
private:
   CDecompMC core;
public:
   void   reset(){ core.Init(); }
   void   winStep(){ core.OnTrade(true); }
   void   loseStep(){ core.OnTrade(false); }
   double factor() const { return core.NextLot(); } // BaseLot × factor が実ロット
   string seqString() const { string s; core.Seq(s, 64); return s; }
};

// ====== System State ======
struct SystemState {
   string  name;            // "A" / "B"
   int     activeTicket;    // 成行ポジ
   int     pendUpTicket;    // OCO上や補充上（SellLimit）
   int     pendDnTicket;    // OCO下や補充下（BuyLimit）
   double  entryPrice;      // 直近エントリ価格（成行）
   int     lastDir;         // +1=BUY, -1=SELL
   CDMCMM  mm;
   void clear(){ activeTicket=0; pendUpTicket=0; pendDnTicket=0; entryPrice=0; lastDir=0; }
};
SystemState A,B;

// ====== Gap Rebalance State ======
enum { RB_MODE_IDLE=0, RB_MODE_SNAP_WAIT=1, RB_MODE_LIMIT_WAIT=2 };
struct RebalanceState {
   bool     busy;
   datetime dwellStart;
   datetime lastAction;
   int      mode;
   int      sideToMove; // 0=A,1=B
   double   targetPrice;
};
RebalanceState rb = {false,0,0,RB_MODE_IDLE,0,0.0};
double gSpreadCorrPips=0.0;

// ====== Price/Type utils ======
double MktPriceByDir(int dir){ return (dir>0) ? Ask : Bid; }
int    OrderTypeByDir(int dir){ return (dir>0) ? OP_BUY : OP_SELL; }

// ====== SL/TP ======
void CalcSLTP(int dir, double entry, double d_pips, double &sl, double &tp){
   double d = Pip2Pt(d_pips);
   if(dir>0){ sl = RoundPrice(entry - d); tp = RoundPrice(entry + d); } // Long: Bid判定で±d
   else     { sl = RoundPrice(entry + d); tp = RoundPrice(entry - d); } // Short: Ask判定で±d
}

// ====== Lot helper（直前評価＋数列ログ） ======
double NormalizeLot(double lot){
   double step = MarketInfo(Symbol(), MODE_LOTSTEP);
   double minL = MarketInfo(Symbol(), MODE_MINLOT);
   double maxL = MarketInfo(Symbol(), MODE_MAXLOT);
   double x = MathMax(minL, MathMin(maxL, MathFloor(lot/step)*step));
   return NormalizeDouble(x, 2);
}
double ComputeLotAndLog(SystemState &S){
   double factor = S.mm.factor();              // 直前評価
   double lot    = NormalizeLot(InpBaseLot * factor);
   string seq    = S.mm.seqString();
   LogAlways(StringFormat("[LOT][%s] seq=%s factor=%.2f base=%.2f lot=%.2f",
             S.name, seq, factor, InpBaseLot, lot));
   return lot;
}

// ====== Ticket Scan ======
void RefreshTickets(){
   A.clear(); A.name="A";
   B.clear(); B.name="B";

   int total = OrdersTotal();
   for(int i=0;i<total;i++){
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol()!=Symbol() || OrderMagicNumber()!=InpMagic) continue;

      string c = OrderComment();
      int type = OrderType();

      bool isA = (StringFind(c,"MoveCatcher_A")==0);
      bool isB = (StringFind(c,"MoveCatcher_B")==0);

      if(type==OP_BUY || type==OP_SELL){
         if(isA){
            A.activeTicket = OrderTicket();
            A.entryPrice   = OrderOpenPrice();
            A.lastDir      = (type==OP_BUY)?+1:-1;
         }else if(isB){
            B.activeTicket = OrderTicket();
            B.entryPrice   = OrderOpenPrice();
            B.lastDir      = (type==OP_BUY)?+1:-1;
         }
      }else if(type==OP_SELLLIMIT || type==OP_BUYLIMIT || type==OP_BUYSTOP || type==OP_SELLSTOP){
         if(isA){
            if(type==OP_SELLLIMIT || type==OP_SELLSTOP) A.pendUpTicket = OrderTicket();
            if(type==OP_BUYLIMIT  || type==OP_BUYSTOP ) A.pendDnTicket = OrderTicket();
         }else if(isB){
            if(type==OP_SELLLIMIT || type==OP_SELLSTOP) B.pendUpTicket = OrderTicket();
            if(type==OP_BUYLIMIT  || type==OP_BUYSTOP ) B.pendDnTicket = OrderTicket();
         }
      }
   }
}

// ====== Close Reason from History ======
int CloseReasonFromHistory(int ticket){
   // 1=TP, -1=SL, 0=unknown
   if(!OrderSelect(ticket, SELECT_BY_TICKET, MODE_HISTORY)) return 0;
   double cp = OrderClosePrice();
   double sl = OrderStopLoss();
   double tp = OrderTakeProfit();
   int type  = OrderType();
   if(tp>0 && Almost(cp,tp,InpReasonTolPoints)) return 1;
   if(sl>0 && Almost(cp,sl,InpReasonTolPoints)) return -1;

   // 保険の近似（Lite割り切り）
   if(type==OP_BUY || type==OP_SELL){
      if(type==OP_BUY && cp>OrderOpenPrice()) return 1;
      if(type==OP_SELL && cp<OrderOpenPrice()) return 1;
      if(type==OP_BUY && cp<OrderOpenPrice()) return -1;
      if(type==OP_SELL && cp>OrderOpenPrice()) return -1;
   }
   return 0;
}

// ====== Send helpers ======
int SendMarket(SystemState &S, int dir){
   RefreshRates();
   double price = MktPriceByDir(dir);
   double sl,tp; CalcSLTP(dir, price, InpGridPips, sl, tp);
   int type = OrderTypeByDir(dir);
   string cmt = StringFormat("MoveCatcher_%s", S.name);
   double lot = ComputeLotAndLog(S);          // ★ 発注直前評価＆数列ログ
   int ticket = OrderSend(Symbol(), type, lot, price, InpSlippagePoints, sl, tp, cmt, InpMagic, 0, clrNONE);
   if(ticket<0){
      LogAlways(StringFormat("[%s][OPEN_FAIL] type=%s err=%d", S.name, (dir>0?"BUY":"SELL"), GetLastError()));
   }else{
      LogAlways(StringFormat("[OPEN][%s] type=%s price=%.5f SL=%.5f TP=%.5f lot=%.2f magic=%d ticket=%d",
               S.name, (dir>0?"BUY":"SELL"), price, sl, tp, lot, InpMagic, ticket));
   }
   return ticket;
}

int SendPending(SystemState &S, double price, int type, string suffixTag){
   price = RoundPrice(price);
   double sl=0, tp=0; // 約定後にSL/TP付与
   string cmt = StringFormat("MoveCatcher_%s%s", S.name, suffixTag);
   double lot = ComputeLotAndLog(S);          // ★ 発注直前評価＆数列ログ
   int ticket = OrderSend(Symbol(), type, lot, price, InpSlippagePoints, sl, tp, cmt, InpMagic, 0, clrNONE);
   if(ticket<0){
      LogAlways(StringFormat("[%s][PEND_FAIL] type=%d@%.5f err=%d", S.name, type, price, GetLastError()));
   }else{
      LogAlways(StringFormat("[PEND_PLACE][%s] type=%d@%.5f lot=%.2f tag=%s", S.name, type, price, lot, suffixTag));
   }
   return ticket;
}

bool DeleteTicket(int ticket, string sysName, string tag){
   if(ticket<=0) return true;
   if(!OrderSelect(ticket, SELECT_BY_TICKET)) return true; // 既に消えてる
   int ot = OrderType();
   if(!(ot==OP_BUYLIMIT || ot==OP_SELLLIMIT || ot==OP_BUYSTOP || ot==OP_SELLSTOP)) return true;
   bool ok = OrderDelete(ticket);
   if(!ok) LogAlways(StringFormat("[%s][PEND_CANCEL_FAIL] ticket=%d err=%d", sysName, ticket, GetLastError()));
   else    LogAlways(StringFormat("[PEND_CANCEL][%s] ticket=%d tag=%s", sysName, ticket, tag));
   return ok;
}

double DistToGoal(int ticket){
   if(!OrderSelect(ticket, SELECT_BY_TICKET)) return 0.0;
   int type = OrderType();
   double distTP, distSL;
   if(type==OP_BUY){
      distTP = OrderTakeProfit() - Bid;
      distSL = Bid - OrderStopLoss();
   }else{
      distTP = Ask - OrderTakeProfit();
      distSL = OrderStopLoss() - Ask;
   }
   return MathMin(distTP, distSL);
}

// ====== Guards ======
bool HasAnyPending(){
   RefreshTickets();
   return (A.pendUpTicket>0 || A.pendDnTicket>0 || B.pendUpTicket>0 || B.pendDnTicket>0);
}
int  MarketCount(){
   int cnt=0;
   RefreshTickets();
   if(A.activeTicket>0) cnt++;
   if(B.activeTicket>0) cnt++;
   return cnt;
}

// ====== Core behaviours ======

// 初期BのOCO（Aが存在し、Bが完全に空の時のみ）
void TryPlaceOCO_B_AroundA(){
   RefreshTickets();
   if(A.activeTicket<=0) return;
   if(B.activeTicket>0 || B.pendUpTicket>0 || B.pendDnTicket>0) return;

   // Spread判定（0で無効）
   double spr = (Ask-Bid)/PIP();
   if(InpMaxSpreadPips>0.0 && spr>InpMaxSpreadPips){
      Log("[OCO_SKIP] spread too wide");
      return;
   }

   double s = Pip2Pt(InpGridPips/2.0);
   double upPrice = A.entryPrice + s;   // SellLimit（上）
   double dnPrice = A.entryPrice - s;   // BuyLimit（下）

   // StopLevel尊重
   double stopLevel = MarketInfo(Symbol(), MODE_STOPLEVEL)*Point;
   if(Ask + stopLevel > upPrice) upPrice = Ask + stopLevel + 2*Point;
   if(dnPrice > Bid - stopLevel) dnPrice = Bid - stopLevel - 2*Point;

   // 2本同時配置（BのMMを使用）
   B.pendUpTicket = SendPending(B, upPrice, OP_SELLLIMIT, "[OCOU]");
   B.pendDnTicket = SendPending(B, dnPrice, OP_BUYLIMIT,  "[OCOD]");
}

// Pending成立後の処理：他脚キャンセル＋SL/TP付与（A/B共通）
void MaintainPendingAfterFill(){
   RefreshTickets();
   SystemState* arr[2] = {&A,&B};
   for(int i=0;i<2;i++){
      SystemState &S = *arr[i];
      if(S.activeTicket>0 && (S.pendUpTicket>0 || S.pendDnTicket>0)){
         if(S.pendUpTicket>0) DeleteTicket(S.pendUpTicket,S.name,"AFTER");
         if(S.pendDnTicket>0) DeleteTicket(S.pendDnTicket,S.name,"AFTER");
         S.pendUpTicket=0; S.pendDnTicket=0;
         if(OrderSelect(S.activeTicket, SELECT_BY_TICKET)){
            int type=OrderType();
            double entry=OrderOpenPrice();
            double sl,tp; CalcSLTP((type==OP_BUY)?+1:-1, entry, InpGridPips, sl, tp);
            bool need=true;
            if(Almost(OrderStopLoss(),sl,1) && Almost(OrderTakeProfit(),tp,1)) need=false;
            if(need){
               bool ok = OrderModify(S.activeTicket, OrderOpenPrice(), sl, tp, 0, clrNONE);
               if(ok) LogAlways(StringFormat("[SLTP_SET][%s] ticket=%d SL=%.5f TP=%.5f", S.name, S.activeTicket, sl, tp));
               else   LogAlways(StringFormat("[SLTP_SET_FAIL][%s] ticket=%d err=%d", S.name, S.activeTicket, GetLastError()));
            }
         }
      }
   }
}

// 欠落時の補充：片側指値を1本だけ（A/Bどちらが欠落でも可）
void TryRefillOneSideIfOneLeft(){
   RefreshTickets();
   int mktCnt = MarketCount();
   if(mktCnt!=1) return;               // 2本 or 0本は対象外
   if(HasAnyPending()) return;         // Pendingを既に持っているなら置かない

   // Spread判定（0で無効）
   double spr = (Ask-Bid)/PIP();
   if(InpMaxSpreadPips>0.0 && spr>InpMaxSpreadPips){
      Log("[REFILL_SKIP] spread too wide");
      return;
   }

   // どちらが生存しているか
   bool aliveIsA = (A.activeTicket>0);

   // 生存側の方向を取得
   int aliveTicket = aliveIsA ? A.activeTicket : B.activeTicket;
   if(!OrderSelect(aliveTicket, SELECT_BY_TICKET)) return;
   int aliveDir = (OrderType()==OP_BUY)? +1 : -1;

   double s = Pip2Pt(InpGridPips/2.0);
   double stopLevel = MarketInfo(Symbol(), MODE_STOPLEVEL)*Point;

   if(aliveIsA){
      // 欠落側 = B、Bへ片側指値を1本
      double price;
      int    ptype;
      if(aliveDir>0){
         price = A.entryPrice + s;     // AがLong→BへSellLimit@A+s
         ptype = OP_SELLLIMIT;
         if(Ask + stopLevel > price) price = Ask + stopLevel + 2*Point;
      }else{
         price = A.entryPrice - s;     // AがShort→BへBuyLimit@A-s
         ptype = OP_BUYLIMIT;
         if(price > Bid - stopLevel) price = Bid - stopLevel - 2*Point;
      }
      int tk = SendPending(B, price, ptype, "[REFILL]");
      if(ptype==OP_SELLLIMIT) B.pendUpTicket=tk; else B.pendDnTicket=tk;
   }else{
      // 欠落側 = A、Aへ片側指値を1本
      double price;
      int    ptype;
      if(aliveDir>0){
         price = B.entryPrice + s;     // BがLong→AへSellLimit@B+s
         ptype = OP_SELLLIMIT;
         if(Ask + stopLevel > price) price = Ask + stopLevel + 2*Point;
      }else{
         price = B.entryPrice - s;     // BがShort→AへBuyLimit@B-s
         ptype = OP_BUYLIMIT;
         if(price > Bid - stopLevel) price = Bid - stopLevel - 2*Point;
      }
   int tk = SendPending(A, price, ptype, "[REFILL]");
      if(ptype==OP_SELLLIMIT) A.pendUpTicket=tk; else A.pendDnTicket=tk;
   }
}

// --- Gap Correction Core ---
void DoRebalanceSnap(){
   SystemState &S = (rb.sideToMove==0)?A:B;
   if(!OrderSelect(S.activeTicket, SELECT_BY_TICKET)) return;
   int dir = S.lastDir;
   int oldTk = S.activeTicket;
   double lotOld = OrderLots();
   double lotNew = lotOld;
   if(InpRebalanceLotMode==RB_RECALC) lotNew = ComputeLotAndLog(S);
   else LogAlways(StringFormat("[LOT_KEEP][%s] lot=%.2f", S.name, lotNew));
   double priceClose = (dir>0)? Bid : Ask;
   bool ok = OrderClose(S.activeTicket, lotOld, priceClose, InpSlippagePoints, clrNONE);
   if(!ok){ LogAlways(StringFormat("[REBALANCE_SNAP_FAIL][%s] close err=%d", S.name, GetLastError())); return; }
   RefreshRates();
   double price = MktPriceByDir(dir);
   double sl,tp; CalcSLTP(dir, price, InpGridPips, sl, tp);
   int type = OrderTypeByDir(dir);
   string cmt = StringFormat("MoveCatcher_%s", S.name);
   int tk = OrderSend(Symbol(), type, lotNew, price, InpSlippagePoints, sl, tp, cmt, InpMagic, 0, clrNONE);
   if(tk>0){
      LogAlways(StringFormat("[REBALANCE_SNAP][%s] P*=%.5f oldTk=%d newTk=%d", S.name, rb.targetPrice, oldTk, tk));
      S.activeTicket=tk; S.entryPrice=price; S.lastDir=dir;
   }else{
      LogAlways(StringFormat("[REBALANCE_SNAP_FAIL][%s] open err=%d", S.name, GetLastError()));
   }
   rb.lastAction=TimeCurrent(); rb.dwellStart=0; rb.mode=RB_MODE_IDLE; rb.busy=false;
}

void DoRebalanceLimit(){
   SystemState &S = (rb.sideToMove==0)?A:B;
   if(!OrderSelect(S.activeTicket, SELECT_BY_TICKET)) return;
   int dir = S.lastDir;
   double lotOld = OrderLots();
   double lotNew = lotOld;
   if(InpRebalanceLotMode==RB_RECALC) lotNew = ComputeLotAndLog(S);
   else LogAlways(StringFormat("[LOT_KEEP][%s] lot=%.2f", S.name, lotNew));
   double priceClose = (dir>0)? Bid : Ask;
   bool ok = OrderClose(S.activeTicket, lotOld, priceClose, InpSlippagePoints, clrNONE);
   if(!ok){ LogAlways(StringFormat("[REBALANCE_LIMIT_FAIL][%s] close err=%d", S.name, GetLastError())); return; }
   S.activeTicket=0;

   // Spread check (MaxSpreadPips)
   double spr = (Ask-Bid)/PIP();
   if(InpMaxSpreadPips>0.0 && spr>InpMaxSpreadPips){
      LogAlways("[REBALANCE_LIMIT_SKIP] spread too wide");
      rb.dwellStart=0; rb.mode=RB_MODE_IDLE; rb.busy=false; return;
   }

   int ptype;
   double price = rb.targetPrice;
   if(dir>0){ ptype = (price<=Ask) ? OP_BUYLIMIT : OP_BUYSTOP; }
   else     { ptype = (price>=Bid) ? OP_SELLLIMIT : OP_SELLSTOP; }
   string tag="[REBAL]";
   int tk = OrderSend(Symbol(), ptype, lotNew, price, InpSlippagePoints, 0,0,
                      StringFormat("MoveCatcher_%s%s",S.name,tag), InpMagic,0,clrNONE);
   if(tk>0){
      if(price>Ask) S.pendUpTicket=tk; else S.pendDnTicket=tk;
      LogAlways(StringFormat("[REBALANCE_LIMIT][%s] P*=%.5f newPend=%d", S.name, price, tk));
   }else{
      LogAlways(StringFormat("[REBALANCE_LIMIT_FAIL][%s] open err=%d", S.name, GetLastError()));
   }
   rb.lastAction=TimeCurrent(); rb.dwellStart=0; rb.mode=RB_MODE_IDLE; rb.busy=false;
}

void GapCorrectionTick(){
   if(!InpGapCorrection) return;
   RefreshRates();
   RefreshTickets();
   if(A.activeTicket<=0 || B.activeTicket<=0){ rb.dwellStart=0; rb.mode=RB_MODE_IDLE; return; }

   double s = Pip2Pt(InpGridPips/2.0);
   double g = MathAbs(A.entryPrice - B.entryPrice);
   double err = g - s;
   double eps = Pip2Pt(InpGapEpsilonPips);
   if(MathAbs(err) <= eps){ rb.dwellStart=0; rb.mode=RB_MODE_IDLE; return; }

   double d = Pip2Pt(InpGridPips);
   double mu = InpNearGoalRatio * d;
   if(DistToGoal(A.activeTicket) <= mu || DistToGoal(B.activeTicket) <= mu){
      LogAlways("[REBALANCE_SKIP_NEARGOAL]"); rb.dwellStart=0; rb.mode=RB_MODE_IDLE; return; }
   if(TimeCurrent() - rb.lastAction < InpGapCooldownSec) return;

   if(rb.dwellStart==0){ rb.dwellStart=TimeCurrent(); return; }
   if(TimeCurrent() - rb.dwellStart < InpGapDwellSec) return;

   double stopLevel = MarketInfo(Symbol(), MODE_STOPLEVEL)*Point;
   double freezeLevel = MarketInfo(Symbol(), MODE_FREEZELEVEL)*Point;
   if(d < stopLevel || d < freezeLevel){
      LogAlways("[REBALANCE_SKIP_FREEZE]"); rb.dwellStart=0; rb.mode=RB_MODE_IDLE; return;
   }

   if(rb.mode==RB_MODE_IDLE){
      // pick side: newer
      int move = 0;
      datetime aTime=0,bTime=0;
      if(OrderSelect(A.activeTicket, SELECT_BY_TICKET)) aTime=OrderOpenTime();
      if(OrderSelect(B.activeTicket, SELECT_BY_TICKET)) bTime=OrderOpenTime();
      move = (aTime>bTime)?0:1;
      rb.sideToMove=move;
      SystemState &Sanch = (move==0)?B:A;
      int anchorDir = Sanch.lastDir;
      double anchorEntry = Sanch.entryPrice;
      rb.targetPrice = RoundPrice( (anchorDir>0)? (anchorEntry + s) : (anchorEntry - s) );
      rb.mode = RB_MODE_SNAP_WAIT;
   }

   double spr = (Ask-Bid)/PIP();
   if(gSpreadCorrPips>0.0 && spr>gSpreadCorrPips){
      if(TimeCurrent() - rb.dwellStart >= InpGapTimeoutSec) DoRebalanceLimit();
      return;
   }

   int dir = (rb.sideToMove==0)? A.lastDir : B.lastDir;
   double priceNow = (dir>0)? Ask : Bid;
   static double prevPriceAsk=0, prevPriceBid=0;
   double prev = (dir>0)? prevPriceAsk : prevPriceBid;
   bool crossed = false;
   if(prev!=0){
      if( (prev<rb.targetPrice && priceNow>=rb.targetPrice) ||
          (prev>rb.targetPrice && priceNow<=rb.targetPrice) ) crossed=true;
   }
   if(crossed){ DoRebalanceSnap(); return; }
   if(TimeCurrent() - rb.dwellStart >= InpGapTimeoutSec){ DoRebalanceLimit(); return; }
   prevPriceAsk=Ask; prevPriceBid=Bid;
}

// TP/SL検知：A/B 共通で成行再エントリ（TP=反転 / SL=順方向）
// 勝敗判定はEA側で行い、DMCMMへ winStep()/loseStep() を明示的に通知
void DetectCloseAndReenter(){
   static int prevA=0, prevB=0;
   static bool inited=false;
   if(!inited){ RefreshTickets(); prevA=A.activeTicket; prevB=B.activeTicket; inited=true; return; }

   RefreshTickets();

   // --- A: 即時再エントリ ---
   if(prevA>0 && A.activeTicket==0){
      int reason = CloseReasonFromHistory(prevA);  // 1=TP, -1=SL
      int dirPrev=0;
      if(OrderSelect(prevA, SELECT_BY_TICKET, MODE_HISTORY)){
         dirPrev = (OrderType()==OP_BUY)?+1:-1;
      }
      if(reason!=0 && dirPrev!=0){
         if(reason>0) A.mm.winStep(); else A.mm.loseStep();
         int dirNew = (reason>0) ? -dirPrev : dirPrev; // TP:反転, SL:順方向
         int tA = SendMarket(A, dirNew);
         if(tA>0){
            A.activeTicket=tA; A.lastDir=dirNew; A.entryPrice=MktPriceByDir(dirNew);
         }
      }
   }

   // --- B: 即時再エントリ ---
   if(prevB>0 && B.activeTicket==0){
      int reasonB = CloseReasonFromHistory(prevB); // 1=TP, -1=SL
      int dirPrevB=0;
      if(OrderSelect(prevB, SELECT_BY_TICKET, MODE_HISTORY)){
         dirPrevB = (OrderType()==OP_BUY)?+1:-1;
      }
      if(reasonB!=0 && dirPrevB!=0){
         if(reasonB>0) B.mm.winStep(); else B.mm.loseStep();
         int dirNewB = (reasonB>0) ? -dirPrevB : dirPrevB; // TP:反転, SL:順方向
         int tB = SendMarket(B, dirNewB);
         if(tB>0){
            B.activeTicket=tB; B.lastDir=dirNewB; B.entryPrice=MktPriceByDir(dirNewB);
         }
      }
   }

   prevA=A.activeTicket; prevB=B.activeTicket;
}

// 2本超過の是正：後着から削除/クローズして2本以内、2本生存中はPendingなし
void EnforceMaxTwo(){
   // 動的配列で収集（未初期化警告の回避）
   struct TRec { int ticket; datetime open; int type; };
   TRec recs[]; int n=0; ArrayResize(recs,0);

   int total=OrdersTotal();
   for(int i=0;i<total;i++){
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol()!=Symbol() || OrderMagicNumber()!=InpMagic) continue;
      int type=OrderType();
      if(type==OP_BUY || type==OP_SELL){
         TRec r; r.ticket=OrderTicket(); r.open=OrderOpenTime(); r.type=type;
         ArrayResize(recs, n+1); recs[n]=r; n++;
      }
   }

   // 2本以下なら以降の処理は不要（Pendingの整理だけ行う）
   if(n<=2) {
      if(n==2){
         RefreshTickets();
         if(A.pendUpTicket>0) DeleteTicket(A.pendUpTicket,"A","ENFORCE");
         if(A.pendDnTicket>0) DeleteTicket(A.pendDnTicket,"A","ENFORCE");
         if(B.pendUpTicket>0) DeleteTicket(B.pendUpTicket,"B","ENFORCE");
         if(B.pendDnTicket>0) DeleteTicket(B.pendDnTicket,"B","ENFORCE");
      }
      return;
   }

   // open昇順にソート（バブル）
   for(int i=0;i<n;i++)
      for(int j=i+1;j<n;j++)
         if(recs[i].open>recs[j].open){ TRec t=recs[i]; recs[i]=recs[j]; recs[j]=t; }

   // 後着からクローズして2本にする
   for(int k=n-1; k>=0 && n>2; k--){
      if(OrderSelect(recs[k].ticket, SELECT_BY_TICKET)){
         double price = (OrderType()==OP_BUY)? Bid : Ask;
         bool ok = OrderClose(OrderTicket(), OrderLots(), price, InpSlippagePoints, clrNONE);
         if(ok){ LogAlways(StringFormat("[ENFORCE][CLOSE_EXTRA] ticket=%d", OrderTicket())); n--; }
         else  { LogAlways(StringFormat("[ENFORCE_FAIL][CLOSE_EXTRA] ticket=%d err=%d", OrderTicket(), GetLastError())); break; }
      }
   }

   // 最終的に2本生存中はPendingなしに整える
   RefreshTickets();
   if(MarketCount()>=2){
      if(A.pendUpTicket>0) DeleteTicket(A.pendUpTicket,"A","ENFORCE");
      if(A.pendDnTicket>0) DeleteTicket(A.pendDnTicket,"A","ENFORCE");
      if(B.pendUpTicket>0) DeleteTicket(B.pendUpTicket,"B","ENFORCE");
      if(B.pendDnTicket>0) DeleteTicket(B.pendDnTicket,"B","ENFORCE");
   }
}

// ====== Start on Launch ======
void StartIfNeeded(){
   RefreshTickets();
   if(!InpStartOnLaunch) return;
   if(A.activeTicket>0) return;

   int dir = (InpStartDir>=0)?+1:-1;
   int tA = SendMarket(A, dir);
   if(tA>0){
     A.activeTicket=tA; A.lastDir=dir; A.entryPrice=MktPriceByDir(dir);
   }
}

// ====== Events ======
int OnInit(){
   A.clear(); A.name="A"; A.mm.reset();
   B.clear(); B.name="B"; B.mm.reset();

   gSpreadCorrPips = (InpSpreadCorrPips>0.0) ? InpSpreadCorrPips : MathMin(InpMaxSpreadPips*1.5, 3.0);

   LogAlways(StringFormat("INIT: StopLevel=%dpt MinLot=%.2f MaxLot=%.2f Step=%.2f",
            (int)MarketInfo(Symbol(), MODE_STOPLEVEL),
            MarketInfo(Symbol(), MODE_MINLOT),
            MarketInfo(Symbol(), MODE_MAXLOT),
            MarketInfo(Symbol(), MODE_LOTSTEP)));

   // 初回A→BのOCO
   StartIfNeeded();
   TryPlaceOCO_B_AroundA();
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason){
   LogAlways("DEINIT");
}

void OnTick(){
   // 1) 状態更新
   RefreshTickets();

   // 2) 3本以上の是正（2本以内 enforce & 2本生存中はPendingなし）
   EnforceMaxTwo();

   // 3) 初期BのOCO（AがありBが空の時のみ）
   TryPlaceOCO_B_AroundA();

   // 4) Pending成立後の整理（他脚キャンセル、SL/TP付与）
   MaintainPendingAfterFill();

   // 5) TP/SL検知 → Aのみ即成行再エントリ、BはMM更新のみ
   DetectCloseAndReenter();

   // 6) 欠落時の補充（片側指値を1本だけ）
   TryRefillOneSideIfOneLeft();

   // 7) Gap Correction
   GapCorrectionTick();
}
