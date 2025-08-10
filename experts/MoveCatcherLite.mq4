#property strict
#include <DecompositionMonteCarloMM.mqh>

// 入力パラメータ
input double GridPips      = 100.0;
input double BaseLot       = 0.10;
input double MaxSpreadPips = 2.0;
input double SlippagePips  = 1.0;
input int    MagicNumber   = 246810;
input bool   InitialBuy    = true;

// 派生値
double s;
double Pip;

// コメント識別子
const string COMMENT_A = "MoveCatcher_A";
const string COMMENT_B = "MoveCatcher_B";


enum MoveCatcherSystem
{
   SYSTEM_A,
   SYSTEM_B
};

string CommentIdentifier(MoveCatcherSystem sys)
{
   return (sys == SYSTEM_A) ? COMMENT_A : COMMENT_B;
}

// DMCMM 状態
CDecompMC state_A;
CDecompMC state_B;

// 勝敗検出用
datetime lastCloseTime[2] = {0, 0};
int      lastTicketsA[];
int      lastTicketsB[];
int      historyTickets[];
datetime historyTimes[];

bool ContainsTicket(const int &arr[], int tk)
{
   for(int i=0;i<ArraySize(arr);i++)
      if(arr[i]==tk) return(true);
   return(false);
}

void AddTicket(int &arr[], int tk)
{
   int n=ArraySize(arr);
   ArrayResize(arr,n+1);
   arr[n]=tk;
}

// 履歴の期間選択を模擬する
bool SelectHistoryRange(datetime start, datetime end)
{
   ArrayResize(historyTickets, 0);
   ArrayResize(historyTimes, 0);
   if(start > end)
      return(false);
   int total = OrdersHistoryTotal();
   for(int i=0; i<total; i++)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY))
         return(false);
      datetime ct = OrderCloseTime();
      if(ct >= start && ct <= end)
      {
         int n = ArraySize(historyTickets);
         ArrayResize(historyTickets, n+1);
         ArrayResize(historyTimes, n+1);
         historyTickets[n] = OrderTicket();
         historyTimes[n]   = ct;
      }
   }
   return(true);
}

double CalcLot(MoveCatcherSystem sys)
{
   double lotFactor = (sys==SYSTEM_A) ? state_A.NextLot() : state_B.NextLot();
   double lotCandidate = BaseLot * lotFactor;
   double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);
   double minLot = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot = MarketInfo(Symbol(), MODE_MAXLOT);
   double lot = lotCandidate;
   int lotDigits = 0;
   if(lotStep > 0)
   {
      double step = lotStep;
      while(MathAbs(step - MathRound(step)) > 1e-8 && lotDigits < 8)
      {
         step *= 10;
         lotDigits++;
      }
      lot = MathFloor(lot/lotStep + 0.5)*lotStep;
      lot = NormalizeDouble(lot, lotDigits);
   }
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   if(lotStep > 0) lot = NormalizeDouble(lot, lotDigits);
   return(lot);
}

double GetSpread()
{
   return (Ask - Bid) / Pip;
}

void LogEvent(string reason, MoveCatcherSystem sys, double entry, double sl, double tp, double spread, double actualLot)
{
   string sysStr   = (sys == SYSTEM_A) ? "A" : "B";
   string entryStr = DoubleToString(entry, _Digits);
   string slStr    = DoubleToString(sl, _Digits);
   string tpStr    = DoubleToString(tp, _Digits);

   PrintFormat("Reason=%s Entry=%s SL=%s TP=%s Spread=%.1f System=%s actualLot=%.2f",
               reason,
               entryStr,
               slStr,
               tpStr,
               spread,
               sysStr,
               actualLot);
}

double MinStopDist()
{
   double stop   = MarketInfo(Symbol(), MODE_STOPLEVEL);
   double freeze = MarketInfo(Symbol(), MODE_FREEZELEVEL);
   // stop と freeze はポイント数 → _Point で価格に換算
   return MathMax(stop, freeze) * _Point;
}

void EnsureTPSL(double entry, bool isBuy, double &sl, double &tp)
{
   double d = GridPips * Pip;
   double minLevel = MinStopDist();
   if(d < minLevel)
      d = minLevel;
   if(isBuy)
   {
      sl = entry - d;
      tp = entry + d;
   }
   else
   {
      sl = entry + d;
      tp = entry - d;
   }
   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);
}

void AdjustPendingPrice(int orderType, double &price)
{
   double minLevel = MinStopDist();
   double ref = (orderType == OP_BUYLIMIT || orderType == OP_BUYSTOP) ? Ask : Bid;
   if(minLevel > 0)
   {
      double diff = MathAbs(price - ref);
      if(diff < minLevel)
      {
         if(price > ref) price = ref + minLevel; else price = ref - minLevel;
      }
   }
   price = NormalizeDouble(price, _Digits);
}

bool RetryOrder(bool isModify, int &ticket, int orderType, double lot, double &price, double &sl, double &tp, string comment)
{
   for(int i=0; i<3; i++)
   {
      RefreshRates();
      if(!isModify && (orderType == OP_BUY || orderType == OP_SELL))
         price = (orderType == OP_BUY ? Ask : Bid);
      bool success = false;
      int err = 0;
      if(isModify)
      {
         success = OrderModify(ticket, price, sl, tp, 0, clrNONE);
         if(!success)
         {
            err = GetLastError();
            PrintFormat("OrderModify failed: %d", err);
         }
      }
      else
      {
         int slippage = (int)MathRound(SlippagePips * Pip / _Point); // pips→pointsに換算し整数化
         ticket = OrderSend(
            Symbol(), orderType, lot, price,
            slippage,
            sl, tp, comment, MagicNumber, 0, clrNONE);
         success = (ticket > 0);
         if(success && (orderType == OP_BUY || orderType == OP_SELL))
         {
            if(OrderSelect(ticket, SELECT_BY_TICKET))
            {
               double entry = OrderOpenPrice();
               double slNew, tpNew;
               EnsureTPSL(entry, orderType == OP_BUY, slNew, tpNew);
               if(sl != slNew || tp != tpNew)
               {
                  if(!OrderModify(ticket, entry, slNew, tpNew, 0, clrNONE))
                  {
                     err = GetLastError();
                     PrintFormat("OrderModify failed: %d", err);
                     if(err == ERR_SERVER_BUSY || err == ERR_TRADE_CONTEXT_BUSY || err == ERR_OFF_QUOTES || err == ERR_REQUOTE)
                     {
                        Sleep(500);
                        continue;
                     }
                     return(false);
                  }
                  price = entry;
                  sl    = slNew;
                  tp    = tpNew;
               }
            }
         }
      }
      if(success)
         return(true);

      if(err == 0)
         err = GetLastError();
      if(err == ERR_INVALID_STOPS)
      {
         break;
      }
      if(err == ERR_INVALID_TRADE_PARAMETERS)
      {
         if(!isModify && orderType != OP_BUY && orderType != OP_SELL)
         {
            AdjustPendingPrice(orderType, price);
            continue;
         }
         break;
      }
      if(err == ERR_SERVER_BUSY || err == ERR_TRADE_CONTEXT_BUSY || err == ERR_OFF_QUOTES || err == ERR_REQUOTE)
      {
         Sleep(500);
         continue;
      }
      break;
   }
   return(false);
}

// 同系統ポジションをすべて収集
int FindPositions(MoveCatcherSystem sys, int &tickets[], datetime &times[])
{
   ArrayResize(tickets, 0);
   ArrayResize(times, 0);
   for(int i=0; i<OrdersTotal(); i++)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderMagicNumber() != MagicNumber || OrderSymbol() != Symbol())
         continue;
      if(OrderComment() != CommentIdentifier(sys))
         continue;
      int type = OrderType();
      if(type != OP_BUY && type != OP_SELL)
         continue;
      int n = ArraySize(tickets);
      ArrayResize(tickets, n+1);
      ArrayResize(times, n+1);
      tickets[n] = OrderTicket();
      times[n]   = OrderOpenTime();
   }
   return ArraySize(tickets);
}

bool CloseTicket(int ticket, MoveCatcherSystem sys)
{
   if(OrderSelect(ticket, SELECT_BY_TICKET))
   {
      double lots = OrderLots();
      double price = (OrderType()==OP_BUY) ? Bid : Ask;
      LogEvent("DUPLICATE_CLOSE", sys, OrderOpenPrice(), OrderStopLoss(), OrderTakeProfit(), GetSpread(), lots);
      ResetLastError();
      bool ok = OrderClose(ticket, lots, price, 0, clrNONE);
      if(!ok)
      {
         int err = GetLastError();
         PrintFormat("OrderClose failed. ticket=%d error=%d", ticket, err);
      }
      return(ok);
   }
   return(false);
}

void CorrectDuplicatePositions()
{
   int ticketsA[]; datetime timesA[];
   int countA = FindPositions(SYSTEM_A, ticketsA, timesA);
   if(countA>1)
   {
      int oldest=0; datetime oldTime=timesA[0];
      for(int i=1;i<countA;i++)
         if(timesA[i]<oldTime){ oldTime=timesA[i]; oldest=i; }
      for(int i=0;i<countA;i++)
         if(i!=oldest) CloseTicket(ticketsA[i], SYSTEM_A);
   }

   int ticketsB[]; datetime timesB[];
   int countB = FindPositions(SYSTEM_B, ticketsB, timesB);
   if(countB>1)
   {
      int oldest=0; datetime oldTime=timesB[0];
      for(int i=1;i<countB;i++)
         if(timesB[i]<oldTime){ oldTime=timesB[i]; oldest=i; }
      for(int i=0;i<countB;i++)
         if(i!=oldest) CloseTicket(ticketsB[i], SYSTEM_B);
   }

   // 最新情報を再取得
   countA = FindPositions(SYSTEM_A, ticketsA, timesA);
   countB = FindPositions(SYSTEM_B, ticketsB, timesB);

   int allTks[]; datetime allTimes[]; int allSys[];
   for(int i=0;i<countA;i++)
   {
      int n=ArraySize(allTks); ArrayResize(allTks,n+1); ArrayResize(allTimes,n+1); ArrayResize(allSys,n+1);
      allTks[n]=ticketsA[i]; allTimes[n]=timesA[i]; allSys[n]=(int)SYSTEM_A;
   }
   for(int i=0;i<countB;i++)
   {
      int n=ArraySize(allTks); ArrayResize(allTks,n+1); ArrayResize(allTimes,n+1); ArrayResize(allSys,n+1);
      allTks[n]=ticketsB[i]; allTimes[n]=timesB[i]; allSys[n]=(int)SYSTEM_B;
   }

   int total = ArraySize(allTks);
   while(total>2)
   {
      int latest=0; datetime lt=allTimes[0];
      for(int i=1;i<total;i++)
         if(allTimes[i]>lt){ lt=allTimes[i]; latest=i; }
      CloseTicket(allTks[latest], (MoveCatcherSystem)allSys[latest]);
      for(int j=latest;j<total-1;j++)
      {
         allTks[j]=allTks[j+1];
         allTimes[j]=allTimes[j+1];
         allSys[j]=allSys[j+1];
      }
      total--;
      ArrayResize(allTks,total); ArrayResize(allTimes,total); ArrayResize(allSys,total);
   }
}

void ProcessClosedTrades(MoveCatcherSystem sys)
{
   int idx = (int)sys;
   string sysStr = (sys == SYSTEM_A) ? "A" : "B";
   datetime lastTime = lastCloseTime[idx];

   // 最新の履歴のみを対象にする
   datetime now = TimeCurrent();
   bool rangeOK = SelectHistoryRange(lastTime, now);
   PrintFormat("ProcessClosedTrades: SelectHistoryRange(%s,%s) ok=%d count=%d", TimeToString(lastTime), TimeToString(now), rangeOK, ArraySize(historyTickets));
   if(!rangeOK)
   {
      PrintFormat("SelectHistoryRange failed: %d", GetLastError());
      return;
   }

   int tickets[]; datetime times[];
   int newTickets[];
   if(sys==SYSTEM_A) ArrayCopy(newTickets,lastTicketsA); else ArrayCopy(newTickets,lastTicketsB);
   datetime newLastTime = lastTime;
   for(int i=0;i<ArraySize(historyTickets);i++)
   {
      int histTk = historyTickets[i];
      datetime ct = historyTimes[i];
      if(!OrderSelect(histTk, SELECT_BY_TICKET, MODE_HISTORY))
      {
         PrintFormat("ProcessClosedTrades: OrderSelect(history) failed ticket=%d err=%d", histTk, GetLastError());
         continue;
      }
      PrintFormat("ProcessClosedTrades: history ticket=%d close=%s magic=%d comment=%s type=%d", histTk, TimeToString(ct), OrderMagicNumber(), OrderComment(), OrderType());
      if(OrderMagicNumber()!=MagicNumber || OrderSymbol()!=Symbol()) continue;
      int type=OrderType(); if(type!=OP_BUY && type!=OP_SELL) continue;
      string comment = OrderComment();
      string prefix = CommentIdentifier(sys);
      if(StringSubstr(comment,0,StringLen(prefix))!=prefix) continue;
      if(ct<lastTime) continue;
      if(ct==lastTime)
      {
         if(sys==SYSTEM_A){ if(ContainsTicket(lastTicketsA,OrderTicket())) continue; }
         else{ if(ContainsTicket(lastTicketsB,OrderTicket())) continue; }
      }
      int n=ArraySize(tickets); ArrayResize(tickets,n+1); ArrayResize(times,n+1);
      tickets[n]=OrderTicket(); times[n]=ct;
      if(ct>newLastTime){ newLastTime=ct; ArrayResize(newTickets,0); AddTicket(newTickets,OrderTicket()); }
      else if(ct==newLastTime && !ContainsTicket(newTickets,OrderTicket())) AddTicket(newTickets,OrderTicket());
   }
   for(int i=0;i<ArraySize(tickets);i++)
   {
      if(!OrderSelect(tickets[i], SELECT_BY_TICKET, MODE_HISTORY))
      {
         PrintFormat("ProcessClosedTrades: OrderSelect(tickets) failed ticket=%d err=%d", tickets[i], GetLastError());
         continue;
      }
      double closePrice = OrderClosePrice();
      double tp = OrderTakeProfit();
      double sl = OrderStopLoss();
      double tol = Pip * SlippagePips;
      int type = OrderType();
      bool isTP = false;
      bool isSL = false;
      if(type == OP_BUY)
      {
         if(tp > 0 && closePrice >= tp - tol) isTP = true;
         if(sl > 0 && closePrice <= sl + tol) isSL = true;
      }
      else if(type == OP_SELL)
      {
         if(tp > 0 && closePrice <= tp + tol) isTP = true;
         if(sl > 0 && closePrice >= sl - tol) isSL = true;
      }
      double entry = OrderOpenPrice();
      double d = GridPips * Pip;
      double tpFallback = 0.0;
      double slFallback = 0.0;
      if(type == OP_BUY)
      {
         tpFallback = entry + d;
         slFallback = entry - d;
         if(!isTP && closePrice >= tpFallback - tol) isTP = true;
         if(!isSL && closePrice <= slFallback + tol) isSL = true;
      }
      else if(type == OP_SELL)
      {
         tpFallback = entry - d;
         slFallback = entry + d;
         if(!isTP && closePrice <= tpFallback + tol) isTP = true;
         if(!isSL && closePrice >= slFallback - tol) isSL = true;
      }

      PrintFormat("ProcessClosedTrades: system=%s ticket=%d close=%f tp=%f sl=%f tpFB=%f slFB=%f tol=%f isTP=%d isSL=%d", sysStr, OrderTicket(), closePrice, tp, sl, tpFallback, slFallback, tol, isTP, isSL);
      if(!(isTP || isSL))
         PrintFormat("ProcessClosedTrades: ticket=%d no TP/SL match", OrderTicket());

      if(isTP || isSL)
      {
         if(sys==SYSTEM_A) state_A.OnTrade(isTP); else state_B.OnTrade(isTP);
         double nextLot = (sys==SYSTEM_A) ? state_A.NextLot() : state_B.NextLot();
         if(isTP) needReverse[idx] = true; else if(isSL) needReEnter[idx] = true;

         // デバッグログ: TP/SL 検知を通知
         string result = isTP ? "TP" : "SL";
         PrintFormat("ProcessClosedTrades: system=%s ticket=%d result=%s nextLot=%f", sysStr, OrderTicket(), result, nextLot);
      }
   }
   lastCloseTime[idx] = newLastTime;
   if(sys==SYSTEM_A) ArrayCopy(lastTicketsA,newTickets); else ArrayCopy(lastTicketsB,newTickets);
}

// チケット保持
int positionTicket[2] = { -1, -1 };
int refillTicket[2]   = { -1, -1 };
int ticketBuyLim      = -1;
int ticketSellLim     = -1;
int lastType[2]       = { 0, 0 };
bool needResendOCO    = false; // 初期OCO再送フラグ
bool needReEnter[2]   = { false, false }; // SL 後の同方向再エントリ
bool needReverse[2]   = { false, false }; // TP 後の反対方向再エントリ

// 関数プロトタイプ
void HandleBExecution(int filledTicket);
int  FindPositions(MoveCatcherSystem sys, int &tickets[], datetime &times[]);
int  FindPosition(MoveCatcherSystem sys);
bool ReEnterSameDirection(MoveCatcherSystem sys);
bool EnterOppositeDirection(MoveCatcherSystem sys);
void ManageSystem(MoveCatcherSystem sys);
void CheckRefill();
void CorrectDuplicatePositions();
bool SelectHistoryRange(datetime start, datetime end);
bool CloseTicket(int ticket, MoveCatcherSystem sys);
void LogEvent(string reason, MoveCatcherSystem sys, double entry, double sl, double tp, double spread, double actualLot);
void EnsureTPSL(double entry, bool isBuy, double &sl, double &tp);
void AdjustPendingPrice(int orderType, double &price);
double GetSpread();

// 初期化
int OnInit()
{
   Pip = (_Digits==3 || _Digits==5) ? 10*_Point : _Point;
   double grid = GridPips;
   double minLevel = MinStopDist();
   if(grid * Pip < minLevel)
   {
      double minPips = minLevel / Pip;
      PrintFormat("GridPips %.1f is below minimum stop distance %.1f pips, adjusting to %.1f", grid, minPips, minPips);
      grid = minPips;
   }
   s = grid / 2.0;

   state_A.Init();
   state_B.Init();

   int initialType = InitialBuy ? OP_BUY : OP_SELL;
   lastType[SYSTEM_A] = initialType;
   lastType[SYSTEM_B] = initialType;

   double actualLot_A = CalcLot(SYSTEM_A);

   double entryA = (initialType == OP_BUY) ? Ask : Bid;
   double slA, tpA;
   EnsureTPSL(entryA, initialType == OP_BUY, slA, tpA);
   if(!RetryOrder(false, positionTicket[SYSTEM_A], initialType, actualLot_A, entryA, slA, tpA, COMMENT_A))
      return(INIT_FAILED);
   LogEvent("INIT", SYSTEM_A, entryA, slA, tpA, GetSpread(), actualLot_A);

   double spread = GetSpread();
   if(MaxSpreadPips <= 0 || spread <= MaxSpreadPips)
   {
      double buyPrice  = entryA - s * Pip;
      double sellPrice = entryA + s * Pip;
      AdjustPendingPrice(OP_BUYLIMIT, buyPrice);
      double sl=0, tp=0;
      double actualLot_B = CalcLot(SYSTEM_B);
      if(RetryOrder(false, ticketBuyLim, OP_BUYLIMIT, actualLot_B, buyPrice, sl, tp, COMMENT_B))
         LogEvent("INIT", SYSTEM_B, buyPrice, 0, 0, spread, actualLot_B);
      AdjustPendingPrice(OP_SELLLIMIT, sellPrice);
      sl=0; tp=0;
      actualLot_B = CalcLot(SYSTEM_B);
      if(RetryOrder(false, ticketSellLim, OP_SELLLIMIT, actualLot_B, sellPrice, sl, tp, COMMENT_B))
         LogEvent("INIT", SYSTEM_B, sellPrice, 0, 0, spread, actualLot_B);
   }

   if(ticketBuyLim < 0 || ticketSellLim < 0)
      needResendOCO = true;

   return(INIT_SUCCEEDED);
}

// ティック処理
void OnTick()
{
   ProcessClosedTrades(SYSTEM_A);
   ProcessClosedTrades(SYSTEM_B);

   CorrectDuplicatePositions();

   if(ticketBuyLim > 0)
   {
      if(OrderSelect(ticketBuyLim, SELECT_BY_TICKET))
      {
         if(OrderType() == OP_BUY)
            HandleBExecution(ticketBuyLim);
      }
      else
         ticketBuyLim = -1;
   }

   if(ticketSellLim > 0)
   {
      if(OrderSelect(ticketSellLim, SELECT_BY_TICKET))
      {
         if(OrderType() == OP_SELL)
            HandleBExecution(ticketSellLim);
      }
      else
         ticketSellLim = -1;
   }

   ManageSystem(SYSTEM_A);
   ManageSystem(SYSTEM_B);
   bool hasPending = needReverse[SYSTEM_A] || needReverse[SYSTEM_B] || needReEnter[SYSTEM_A] || needReEnter[SYSTEM_B];
   if(needResendOCO)
   {
      if(positionTicket[SYSTEM_B] > 0)
         needResendOCO = false;
      else if(positionTicket[SYSTEM_A] > 0 && (ticketBuyLim < 0 || ticketSellLim < 0))
      {
         if(OrderSelect(positionTicket[SYSTEM_A], SELECT_BY_TICKET))
         {
            double entryA = OrderOpenPrice();
            double spread = GetSpread();
            if(MaxSpreadPips <= 0 || spread <= MaxSpreadPips)
            {
               double buyPrice  = entryA - s * Pip;
               double sellPrice = entryA + s * Pip;
               if(ticketBuyLim < 0)
               {
                  AdjustPendingPrice(OP_BUYLIMIT, buyPrice);
                  double sl=0, tp=0;
                  double actualLot_B = CalcLot(SYSTEM_B);
                  if(RetryOrder(false, ticketBuyLim, OP_BUYLIMIT, actualLot_B, buyPrice, sl, tp, COMMENT_B))
                     LogEvent("INIT", SYSTEM_B, buyPrice, 0, 0, spread, actualLot_B);
               }
               if(ticketSellLim < 0)
               {
                  AdjustPendingPrice(OP_SELLLIMIT, sellPrice);
                  double sl=0, tp=0;
                  double actualLot_B = CalcLot(SYSTEM_B);
                  if(RetryOrder(false, ticketSellLim, OP_SELLLIMIT, actualLot_B, sellPrice, sl, tp, COMMENT_B))
                     LogEvent("INIT", SYSTEM_B, sellPrice, 0, 0, spread, actualLot_B);
               }
               if(ticketBuyLim > 0 && ticketSellLim > 0)
                  needResendOCO = false;
            }
         }
      }
   }
   else if(!hasPending)
      CheckRefill();
}

// ポジション検索
int FindPosition(MoveCatcherSystem sys)
{
   int tickets[]; datetime times[];
   if(FindPositions(sys, tickets, times) > 0)
      return tickets[0];
   return -1;
}

// 同方向に成行再エントリ
bool ReEnterSameDirection(MoveCatcherSystem sys)
{
   int idx = (int)sys;
   int type = lastType[idx];
   double actualLot = CalcLot(sys);
   double price = (type == OP_BUY) ? Ask : Bid;
   double sl, tp;
   EnsureTPSL(price, type==OP_BUY, sl, tp);
   if(RetryOrder(false, positionTicket[idx], type, actualLot, price, sl, tp, CommentIdentifier(sys)))
   {
      lastType[idx] = type;
      LogEvent("SL_REENTRY", sys, price, sl, tp, GetSpread(), actualLot);
      return(true);
   }
   return(false);
}

// 反対方向に成行エントリ
bool EnterOppositeDirection(MoveCatcherSystem sys)
{
   int idx = (int)sys;
   int type = (lastType[idx] == OP_BUY) ? OP_SELL : OP_BUY;
   double actualLot = CalcLot(sys);
   double price = (type == OP_BUY) ? Ask : Bid;
   double sl, tp;
   EnsureTPSL(price, type==OP_BUY, sl, tp);
   if(RetryOrder(false, positionTicket[idx], type, actualLot, price, sl, tp, CommentIdentifier(sys)))
   {
      lastType[idx] = type;
      LogEvent("TP_REVERSE", sys, price, sl, tp, GetSpread(), actualLot);
      return(true);
   }
   return(false);
}

// システム管理
void ManageSystem(MoveCatcherSystem sys)
{
   int idx = (int)sys;
   int current = FindPosition(sys);

   if(current > 0 && current != positionTicket[idx])
   {
      positionTicket[idx] = current;
      if(OrderSelect(current, SELECT_BY_TICKET))
      {
         int prevType = lastType[idx];
         lastType[idx] = OrderType();
         double entry = OrderOpenPrice();
         double sl, tp;
         EnsureTPSL(entry, lastType[idx]==OP_BUY, sl, tp);
         if(RetryOrder(true, current, 0, 0, entry, sl, tp, ""))
         {
            string reason;
            if(current == refillTicket[idx])
            {
               reason = "REFILL";
               refillTicket[idx] = -1;
            }
            else if(prevType != lastType[idx])
               reason = "TP_REVERSE";
            else
               reason = "SL_REENTRY";
            LogEvent(reason, sys, entry, sl, tp, GetSpread(), OrderLots());
         }
         else
         {
            positionTicket[idx] = -1;
         }
      }
      needReEnter[idx] = false;
      needReverse[idx] = false;
      return;
   }

   if(current > 0)
   {
      positionTicket[idx] = current;
      if(OrderSelect(current, SELECT_BY_TICKET))
         lastType[idx] = OrderType();
      needReEnter[idx] = false;
      needReverse[idx] = false;
      return;
   }

   positionTicket[idx] = -1;

   if(needReverse[idx])
   {
      if(EnterOppositeDirection(sys))
      {
         needReverse[idx] = false;
         if(refillTicket[idx] > 0)
         {
            if(OrderSelect(refillTicket[idx], SELECT_BY_TICKET))
            {
               ResetLastError();
               bool delOk = OrderDelete(refillTicket[idx]);
               if(!delOk)
               {
                  int err = GetLastError();
                  PrintFormat("OrderDelete failed (ticket=%d, err=%d)", refillTicket[idx], err);
                  ResetLastError();
                  delOk = OrderDelete(refillTicket[idx]);
                  if(!delOk)
                  {
                     err = GetLastError();
                     PrintFormat("OrderDelete retry failed (ticket=%d, err=%d)", refillTicket[idx], err);
                  }
               }
               if(delOk || !OrderSelect(refillTicket[idx], SELECT_BY_TICKET))
                  refillTicket[idx] = -1;
            }
            else
               refillTicket[idx] = -1;
         }
      }
      return;
   }

   if(needReEnter[idx])
   {
      if(ReEnterSameDirection(sys))
      {
         needReEnter[idx] = false;
         if(refillTicket[idx] > 0)
         {
            if(OrderSelect(refillTicket[idx], SELECT_BY_TICKET))
            {
               ResetLastError();
               bool delOk = OrderDelete(refillTicket[idx]);
               if(!delOk)
               {
                  int err = GetLastError();
                  PrintFormat("OrderDelete failed (ticket=%d, err=%d)", refillTicket[idx], err);
                  ResetLastError();
                  delOk = OrderDelete(refillTicket[idx]);
                  if(!delOk)
                  {
                     err = GetLastError();
                     PrintFormat("OrderDelete retry failed (ticket=%d, err=%d)", refillTicket[idx], err);
                  }
               }
               if(delOk || !OrderSelect(refillTicket[idx], SELECT_BY_TICKET))
                  refillTicket[idx] = -1;
            }
            else
               refillTicket[idx] = -1;
         }
      }
   }
}

// 補充指値をチェック
void CheckRefill()
{
   int posA = FindPosition(SYSTEM_A);
   int posB = FindPosition(SYSTEM_B);
   bool hasA = (posA > 0);
   bool hasB = (posB > 0);

   for(int i=0; i<2; i++)
   {
      if(refillTicket[i] > 0)
      {
         if(OrderSelect(refillTicket[i], SELECT_BY_TICKET))
         {
            int type = OrderType();
            if(type == OP_BUY || type == OP_SELL)
               refillTicket[i] = -1;
         }
         else
            refillTicket[i] = -1;
      }
   }

   if(hasA && !hasB && ticketBuyLim < 0 && ticketSellLim < 0 && refillTicket[SYSTEM_B] < 0)
   {
      if(OrderSelect(posA, SELECT_BY_TICKET))
      {
         double entry = OrderOpenPrice();
         int type = OrderType();
         double spread = GetSpread();
         if(MaxSpreadPips <= 0 || spread <= MaxSpreadPips)
         {
            double actualLot = CalcLot(SYSTEM_B);
            double price;
            int orderType;
            if(type == OP_BUY)
            {
               price = entry + s * Pip;
               orderType = OP_SELLLIMIT;
            }
            else
            {
               price = entry - s * Pip;
               orderType = OP_BUYLIMIT;
            }
            AdjustPendingPrice(orderType, price);
            double sl=0, tp=0;
            if(RetryOrder(false, refillTicket[SYSTEM_B], orderType, actualLot, price, sl, tp, COMMENT_B))
               LogEvent("REFILL", SYSTEM_B, price, 0, 0, spread, actualLot);
         }
      }
   }
   // Buy/Sell の指値が残っている場合は補充注文を出さない（重複発注を防ぐ）
   else if(!hasA && hasB && ticketBuyLim < 0 && ticketSellLim < 0 && refillTicket[SYSTEM_A] < 0)
   {
      if(OrderSelect(posB, SELECT_BY_TICKET))
      {
         double entry = OrderOpenPrice();
         int type = OrderType();
         double spread = GetSpread();
         if(MaxSpreadPips <= 0 || spread <= MaxSpreadPips)
         {
            double actualLot = CalcLot(SYSTEM_A);
            double price;
            int orderType;
            if(type == OP_BUY)
            {
               price = entry + s * Pip;
               orderType = OP_SELLLIMIT;
            }
            else
            {
               price = entry - s * Pip;
               orderType = OP_BUYLIMIT;
            }
            AdjustPendingPrice(orderType, price);
            double sl=0, tp=0;
            if(RetryOrder(false, refillTicket[SYSTEM_A], orderType, actualLot, price, sl, tp, COMMENT_A))
               LogEvent("REFILL", SYSTEM_A, price, 0, 0, spread, actualLot);
         }
      }
   }
}

// B成立時処理
void HandleBExecution(int filledTicket)
{
   if(filledTicket == ticketBuyLim)
   {
      if(ticketSellLim > 0)
      {
         bool exists = OrderSelect(ticketSellLim, SELECT_BY_TICKET) && OrderType() == OP_SELLLIMIT;
         if(exists)
         {
            LogEvent("OCO_CANCEL", SYSTEM_B, OrderOpenPrice(), 0, 0, GetSpread(), OrderLots());
            ResetLastError();
            bool delOk = OrderDelete(ticketSellLim);
            if(!delOk)
            {
               int err = GetLastError();
               PrintFormat("OrderDelete failed (ticket=%d, err=%d)", ticketSellLim, err);
               ResetLastError();
               delOk = OrderDelete(ticketSellLim);
               if(!delOk)
               {
                  err = GetLastError();
                  PrintFormat("OrderDelete retry failed (ticket=%d, err=%d)", ticketSellLim, err);
               }
            }
            if(delOk || !OrderSelect(ticketSellLim, SELECT_BY_TICKET))
               ticketSellLim = -1;
         }
         else
            ticketSellLim = -1;
      }
      ticketBuyLim = -1; // 約定済みチケットをリセット
   }
   else if(filledTicket == ticketSellLim)
   {
      if(ticketBuyLim > 0)
      {
         bool exists = OrderSelect(ticketBuyLim, SELECT_BY_TICKET) && OrderType() == OP_BUYLIMIT;
         if(exists)
         {
            LogEvent("OCO_CANCEL", SYSTEM_B, OrderOpenPrice(), 0, 0, GetSpread(), OrderLots());
            ResetLastError();
            bool delOk = OrderDelete(ticketBuyLim);
            if(!delOk)
            {
               int err = GetLastError();
               PrintFormat("OrderDelete failed (ticket=%d, err=%d)", ticketBuyLim, err);
               ResetLastError();
               delOk = OrderDelete(ticketBuyLim);
               if(!delOk)
               {
                  err = GetLastError();
                  PrintFormat("OrderDelete retry failed (ticket=%d, err=%d)", ticketBuyLim, err);
               }
            }
            if(delOk || !OrderSelect(ticketBuyLim, SELECT_BY_TICKET))
               ticketBuyLim = -1;
         }
         else
            ticketBuyLim = -1;
      }
      ticketSellLim = -1; // 約定済みチケットをリセット
   }

   if(OrderSelect(filledTicket, SELECT_BY_TICKET))
   {
      double entry = OrderOpenPrice();
      double sl, tp;
      EnsureTPSL(entry, OrderType()==OP_BUY, sl, tp);
      if(RetryOrder(true, filledTicket, 0, 0, entry, sl, tp, ""))
      {
         positionTicket[SYSTEM_B] = filledTicket;
         lastType[SYSTEM_B] = OrderType();
         LogEvent("OCO_HIT", SYSTEM_B, entry, sl, tp, GetSpread(), OrderLots());
      }
   }
}


