//+------------------------------------------------------------------+
//|                                                  MoveCatcher.mq4 |
//| A/B二系統（Ultimate-Lite Strict, 実TP/実SL）                     |
//|  - 初期化: Aを成行で1本建て、Bは置かず監視のみ                   |
//|  - TP/SL決済時のみ勝敗判定→反転/順方向へ即時成行建て直し        |
//|  - 欠落補充: 生存側建値±sに触れた瞬間だけ成行（疑似MIT）        |
//|  - Pending/OCOは一切使わず、Spread判定は発注直前のみ（0で無効） |
//|  - 実ロット = BaseLot × DMCMM係数（発注直前に毎回評価）         |
//|  - A/Bロット計算は UseSharedDMCMM=falseで独立、trueで共通       |
//|  - 補充はNeutral（winStep/loseStep は呼ばない）                 |
//|  - 最大2本を厳守し、異常時はSANITY_TRIMで後着から整流           |
//|  - LogModeで詳細ログと最小限ログを切り替え可能                 |
//+------------------------------------------------------------------+
#property strict

// ====== Includes ======
#include "DecompositionMonteCarloMM.mqh"

// ====== Inputs ======
input double   InpGridPips       = 100;     // d: TP/SL 距離（pips）(TPはd+InpTpOffsetPips)
input double   InpTpOffsetPips   = 0;       // TPオフセット（pips）
input double   InpBaseLot        = 0.01;    // BaseLot
input double   InpMaxSpreadPips  = 2.0;     // 置く時の最大スプレッド[pips]（0で無効）
input int      InpMagic          = 246810;  // マジック
input bool     InpUseSharedDMCMM = false;   // trueでA/B共通DMCMM
enum ENUM_LOG_MODE { LOG_FULL=0, LOG_MIN=1 };
input ENUM_LOG_MODE InpLogMode   = LOG_FULL; // ログ出力モード

// ====== Constants ======
#define EPS_PIPS 0.3                        // 補充許容[pips]
const int  REASON_TOL_POINTS = 10;          // TP/SL判定許容[point]
int EpsilonPoints            = 0;           // OrderSend.deviation

// ====== Helpers ======
double PIP(void){ return (Digits==3 || Digits==5) ? (10.0*Point) : Point; }
double Pip2Pt(double pips){ return pips * PIP(); }
double RoundPrice(double price){ return NormalizeDouble(price, Digits); }
bool   Almost(double a,double b,double tolPts){ return MathAbs(a-b) <= tolPts*Point; }

string TF(){ return EnumToString((ENUM_TIMEFRAMES)Period()); }
string LotMode(){ return InpUseSharedDMCMM?"SHARED":"INDEPENDENT"; }
void Log(string msg){
   if(InpLogMode==LOG_FULL)
      Print(Symbol(),",",TF(),": ",msg," LotMode=",LotMode());
}
void LogAlways(string msg){
   Print(Symbol(),",",TF(),": ",msg," LotMode=",LotMode());
}

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
   double  entryPrice;      // 直近エントリ価格（成行）
   int     lastDir;         // +1=BUY, -1=SELL
   CDMCMM  mm;
   void clear(){ activeTicket=0; entryPrice=0; lastDir=0; }
};
SystemState A,B;
CDMCMM DMCMM_SHARED;           // UseSharedDMCMM=true のとき共通で使用

double LotFactor(SystemState &S){
   return InpUseSharedDMCMM ? DMCMM_SHARED.factor() : S.mm.factor();
}
string SeqString(SystemState &S){
   return InpUseSharedDMCMM ? DMCMM_SHARED.seqString() : S.mm.seqString();
}
void WinStep(SystemState &S){
   if(InpUseSharedDMCMM) DMCMM_SHARED.winStep(); else S.mm.winStep();
}
void LoseStep(SystemState &S){
   if(InpUseSharedDMCMM) DMCMM_SHARED.loseStep(); else S.mm.loseStep();
}

// ====== Price/Type utils ======
double MktPriceByDir(int dir){ return (dir>0) ? Ask : Bid; }
int    OrderTypeByDir(int dir){ return (dir>0) ? OP_BUY : OP_SELL; }

// ====== SL/TP ======
void CalcSLTP(int dir, double entry, double d_pips, double &sl, double &tp){
   double d = Pip2Pt(d_pips);
   double o = Pip2Pt(InpTpOffsetPips);
   if(dir>0){ sl = RoundPrice(entry - d); tp = RoundPrice(entry + d + o); } // Long: SL=d, TP=d+o
   else     { sl = RoundPrice(entry + d); tp = RoundPrice(entry - d - o); } // Short: SL=d, TP=d+o
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
   double factor = LotFactor(S);               // 直前評価
   double lot    = NormalizeLot(InpBaseLot * factor);
   string seq    = SeqString(S);
    Log(StringFormat("[LOT][%s] seq=%s factor=%.2f base=%.2f lot=%.2f",
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
   if(tp>0 && Almost(cp,tp,REASON_TOL_POINTS)) return 1;
   if(sl>0 && Almost(cp,sl,REASON_TOL_POINTS)) return -1;

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
   double spr = (Ask-Bid)/PIP();
   if(InpMaxSpreadPips>0.0 && spr>InpMaxSpreadPips){
      Log(StringFormat("[OPEN_SKIP_SPREAD][%s] spr=%.1f", S.name, spr));
      return 0;
   }
   double price = MktPriceByDir(dir);
   double sl,tp; CalcSLTP(dir, price, InpGridPips, sl, tp);

   int type = OrderTypeByDir(dir);
   string cmt = StringFormat("MoveCatcher_%s", S.name);
   double lot = ComputeLotAndLog(S);          // ★ 発注直前評価＆数列ログ
   int ticket = OrderSend(Symbol(), type, lot, price, EpsilonPoints, sl, tp, cmt, InpMagic, 0, clrNONE);
   if(ticket<0){
      LogAlways(StringFormat("[%s][OPEN_FAIL] type=%s err=%d", S.name, (dir>0?"BUY":"SELL"), GetLastError()));
   }else{
      Log(StringFormat("[OPEN][%s] type=%s price=%.5f SL=%.5f TP=%.5f lot=%.2f magic=%d ticket=%d",
             S.name, (dir>0?"BUY":"SELL"), price, sl, tp, lot, InpMagic, ticket));
   }
   return ticket;
}

// ====== Guards ======
int  MarketCount(){
   int cnt=0;
   if(A.activeTicket>0) cnt++;
   if(B.activeTicket>0) cnt++;
   return cnt;
}

// ====== Core behaviours ======

// 欠落時の補充：疑似MIT（Pendingを使わず生存側建値±sで成行）
void TryRefillOneSideIfOneLeft(){
   static bool armed=false;
   static string armSys="";
   static double armPrice=0.0;
   static int armDir=0;
   static double prevDiff=1e9;      // 直前の価格乖離（ヒット判定用）

   RefreshTickets();
   int mktCnt = MarketCount();
   if(mktCnt!=1){ armed=false; prevDiff=1e9; return; }

   // 生存側と欠落側
   bool aliveIsA = (A.activeTicket>0);
   double s = Pip2Pt(InpGridPips/2.0);
   double target;         // 生存側建値±s
   int    dir;            // 補充方向（生存側反転）
   string missingName;    // 欠落系統名

   if(aliveIsA){
      target      = A.entryPrice + ((A.lastDir>0)? s : -s);
      dir         = (A.lastDir>0)? -1 : +1;
      missingName = B.name;
   }else{
      target      = B.entryPrice + ((B.lastDir>0)? s : -s);
      dir         = (B.lastDir>0)? -1 : +1;
      missingName = A.name;
   }

   if(!armed || armSys!=missingName || !Almost(armPrice,target,1)){
      armed=true; armSys=missingName; armPrice=target; armDir=dir; prevDiff=1e9;
      LogAlways(StringFormat("[REFILL_STRICT_ARM][%s] P*=%.5f", missingName, target));
   }

   // Spread判定（0で無効）
   double spr = (Ask-Bid)/PIP();
   if(InpMaxSpreadPips>0.0 && spr>InpMaxSpreadPips){
      Log("[REFILL_STRICT_SKIP_SPREAD]");
      return;
   }

   double eps = Pip2Pt(EPS_PIPS);
   double diff = (dir>0) ? MathAbs(Ask - target) : MathAbs(Bid - target);
   bool hit = (diff<=eps && prevDiff>eps);
   prevDiff = diff;
   if(!hit) return;                // 未到達 or 滞留中

   int tk;
   if(aliveIsA) tk = SendMarket(B, dir); else tk = SendMarket(A, dir); // Neutral: win/lose 更新なし
   if(tk>0){
      if(aliveIsA){
         B.activeTicket=tk; B.lastDir=dir; B.entryPrice=MktPriceByDir(dir);
         LogAlways(StringFormat("[REFILL_STRICT_HIT][%s] ticket=%d", B.name, tk));
      }else{
         A.activeTicket=tk; A.lastDir=dir; A.entryPrice=MktPriceByDir(dir);
         LogAlways(StringFormat("[REFILL_STRICT_HIT][%s] ticket=%d", A.name, tk));
      }
      armed=false; prevDiff=1e9;
   }else{
      int err=GetLastError();
      string tag = (err==ERR_REQUOTE || err==ERR_OFF_QUOTES)?"REFILL_STRICT_REQUOTE":"REFILL_STRICT_REJECT";
      LogAlways(StringFormat("[%s][%s] err=%d", tag, missingName, err));
   }
}

// TP/SL検知：A/B 共通で成行再エントリ（TP=反転 / SL=順方向）
// 勝敗判定はEA側で行い、DMCMMへ winStep()/loseStep() を明示的に通知
void DetectCloseAndReenter(){
   static int prevA=0, prevB=0;
   static int pendDirA=0, pendDirB=0;   // 再エントリ未成時の方向を保持
   static bool inited=false;
   if(!inited){ RefreshTickets(); prevA=A.activeTicket; prevB=B.activeTicket; inited=true; return; }

   RefreshTickets();

   // ---- 未決再エントリの再試行 ----
   if(pendDirA!=0 && A.activeTicket==0){
      int t = SendMarket(A, pendDirA);
      if(t>0){ A.activeTicket=t; A.lastDir=pendDirA; A.entryPrice=MktPriceByDir(pendDirA); pendDirA=0; prevA=A.activeTicket; }
   }
   if(pendDirB!=0 && B.activeTicket==0){
      int t = SendMarket(B, pendDirB);
      if(t>0){ B.activeTicket=t; B.lastDir=pendDirB; B.entryPrice=MktPriceByDir(pendDirB); pendDirB=0; prevB=B.activeTicket; }
   }

   // ---- 閉鎖イベント収集 ----
   struct CloseEvent { int sys; int reason; int dirPrev; datetime closeTime; int ticket; };
   CloseEvent evs[]; int n=0; ArrayResize(evs,0);

   if(prevA>0 && A.activeTicket==0 && pendDirA==0){
      int reason = CloseReasonFromHistory(prevA);  // 1=TP, -1=SL
      int dirPrev=0; datetime ct=0;
      if(OrderSelect(prevA, SELECT_BY_TICKET, MODE_HISTORY)){
         dirPrev = (OrderType()==OP_BUY)?+1:-1;
         ct      = OrderCloseTime();
      }
      if(reason!=0 && dirPrev!=0){
         CloseEvent e; e.sys=0; e.reason=reason; e.dirPrev=dirPrev; e.closeTime=ct; e.ticket=prevA;
         ArrayResize(evs, n+1); evs[n]=e; n++;
      }
      prevA=0; // 閉鎖済
   }
   if(prevB>0 && B.activeTicket==0 && pendDirB==0){
      int reason = CloseReasonFromHistory(prevB);  // 1=TP, -1=SL
      int dirPrev=0; datetime ct=0;
      if(OrderSelect(prevB, SELECT_BY_TICKET, MODE_HISTORY)){
         dirPrev = (OrderType()==OP_BUY)?+1:-1;
         ct      = OrderCloseTime();
      }
      if(reason!=0 && dirPrev!=0){
         CloseEvent e; e.sys=1; e.reason=reason; e.dirPrev=dirPrev; e.closeTime=ct; e.ticket=prevB;
         ArrayResize(evs, n+1); evs[n]=e; n++;
      }
      prevB=0; // 閉鎖済
   }

   // ---- クローズ時刻→チケット番号順にソート ----
   for(int i=0;i<n;i++)
      for(int j=i+1;j<n;j++)
         if(evs[i].closeTime>evs[j].closeTime ||
            (evs[i].closeTime==evs[j].closeTime && evs[i].ticket>evs[j].ticket)){
            CloseEvent t=evs[i]; evs[i]=evs[j]; evs[j]=t; }

   // ---- 順次更新＆再エントリ ----
   for(int k=0;k<n;k++){
      int reason = evs[k].reason;
      int dirPrev = evs[k].dirPrev;
      int ticket = evs[k].ticket;
      if(evs[k].sys==0){
         if(reason>0){
            WinStep(A);
            LogAlways(StringFormat("TP_REVERSE[%s] ticket=%d", A.name, ticket));
         }else{
            LoseStep(A);
            LogAlways(StringFormat("SL_REENTRY[%s] ticket=%d", A.name, ticket));
         }
         int dirNew = (reason>0) ? -dirPrev : dirPrev;
         int tNew = SendMarket(A, dirNew);
         if(tNew>0){
            A.activeTicket=tNew; A.lastDir=dirNew; A.entryPrice=MktPriceByDir(dirNew); prevA=A.activeTicket;
         }else{
            pendDirA=dirNew; // 次ティック以降で再試行
         }
      }else{
         if(reason>0){
            WinStep(B);
            LogAlways(StringFormat("TP_REVERSE[%s] ticket=%d", B.name, ticket));
         }else{
            LoseStep(B);
            LogAlways(StringFormat("SL_REENTRY[%s] ticket=%d", B.name, ticket));
         }
         int dirNew = (reason>0) ? -dirPrev : dirPrev;
         int tNew = SendMarket(B, dirNew);
         if(tNew>0){
            B.activeTicket=tNew; B.lastDir=dirNew; B.entryPrice=MktPriceByDir(dirNew); prevB=B.activeTicket;
         }else{
            pendDirB=dirNew; // 次ティック以降で再試行
         }
      }
   }

   if(pendDirA==0) prevA=A.activeTicket;
   if(pendDirB==0) prevB=B.activeTicket;
}

// 2本超過/同系統重複の是正：後着からクローズして最大1本×2系統に収束
void EnforceMaxTwo(){
   struct TRec { int ticket; datetime open; int type; string sys; };
   TRec recs[]; int n=0; ArrayResize(recs,0);

   int total=OrdersTotal();
   for(int i=0;i<total;i++){
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol()!=Symbol() || OrderMagicNumber()!=InpMagic) continue;
      int type=OrderType();
      if(type==OP_BUY || type==OP_SELL){
         string c=OrderComment();
         string sys=(StringFind(c,"MoveCatcher_A")==0)?"A":
                    (StringFind(c,"MoveCatcher_B")==0)?"B":"";
         TRec r; r.ticket=OrderTicket(); r.open=OrderOpenTime(); r.type=type; r.sys=sys;
         ArrayResize(recs, n+1); recs[n]=r; n++;
      }
   }

   // open昇順にソート
   for(int i=0;i<n;i++)
      for(int j=i+1;j<n;j++)
         if(recs[i].open>recs[j].open){ TRec t=recs[i]; recs[i]=recs[j]; recs[j]=t; }

   bool haveA=false, haveB=false; int kept=0;
   for(int k=0;k<n;k++){
      bool close=false;
      if(recs[k].sys=="A"){
         if(haveA) close=true; else haveA=true;
      }else if(recs[k].sys=="B"){
         if(haveB) close=true; else haveB=true;
      }
      if(!close && kept>=2) close=true; // 合計3本以上 → 後着から削除

      if(close && OrderSelect(recs[k].ticket, SELECT_BY_TICKET)){
         double price = (OrderType()==OP_BUY)? Bid : Ask;
         bool ok = OrderClose(OrderTicket(), OrderLots(), price, EpsilonPoints, clrNONE);
         if(ok) LogAlways(StringFormat("SANITY_TRIM: ticket=%d", OrderTicket()));
         else   LogAlways(StringFormat("SANITY_TRIM_FAIL: ticket=%d err=%d", OrderTicket(), GetLastError()));
      }else if(!close){
         kept++;
      }
   }
}


// ====== Events ======
int OnInit(){
   A.clear(); A.name="A"; A.mm.reset();
   B.clear(); B.name="B"; B.mm.reset();
   DMCMM_SHARED.reset();
   EpsilonPoints = (int)MathRound(EPS_PIPS * PIP() / Point);

   LogAlways(StringFormat("INIT: StopLevel=%dpt MinLot=%.2f MaxLot=%.2f Step=%.2f",
            (int)MarketInfo(Symbol(), MODE_STOPLEVEL),
            MarketInfo(Symbol(), MODE_MINLOT),
            MarketInfo(Symbol(), MODE_MAXLOT),
            MarketInfo(Symbol(), MODE_LOTSTEP)));

   // 初回Aのみ成行で建てる
   int dir = +1;
   int tA = SendMarket(A, dir);
   if(tA>0){
     A.activeTicket=tA; A.lastDir=dir; A.entryPrice=MktPriceByDir(dir);
   }
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason){
   LogAlways("DEINIT");
}

void OnTick(){
   // 1) 状態更新
   RefreshTickets();

   // 2) 3本以上の是正
   EnforceMaxTwo();

   // 3) TP/SL検知 → 即時再エントリ
   DetectCloseAndReenter();

   // 4) 欠落時の補充（疑似MIT）
   TryRefillOneSideIfOneLeft();
}
