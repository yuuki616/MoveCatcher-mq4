#property strict
#include <DecompositionMonteCarloMM.mqh>

// 入力パラメータ
input double GridPips      = 100.0;
input double BaseLot       = 0.10;
input double MaxSpreadPips = 2.0;
input int    MagicNumber   = 246810;

// 派生値
const double s   = GridPips / 2.0;
const double Pip = (Digits == 3 || Digits == 5) ? 10 * Point : Point;

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
      lot = MathRound(lot/lotStep)*lotStep;
      lotDigits = (int)MathRound(-MathLog(lotStep)/MathLog(10.0));
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
   string sysStr = (sys == SYSTEM_A) ? "A" : "B";
   PrintFormat("Reason=%s Entry=%.*f SL=%.*f TP=%.*f Spread=%.1f System=%s actualLot=%.2f",
               reason,
               _Digits, entry,
               _Digits, sl,
               _Digits, tp,
               spread,
               sysStr,
               actualLot);
}

double MinStopDist()
{
   double stop   = MarketInfo(Symbol(), MODE_STOPLEVEL);
   double freeze = MarketInfo(Symbol(), MODE_FREEZELEVEL);
   return MathMax(stop, freeze) * Point;
}

void AdjustStops(bool isBuy, double &sl, double &tp)
{
   double minLevel = MinStopDist();
   double bid = Bid;
   double ask = Ask;
   if(minLevel > 0)
   {
      if(isBuy)
      {
         if(bid - sl < minLevel) sl = bid - minLevel;
         if(tp - ask < minLevel) tp = ask + minLevel;
      }
      else
      {
         if(sl - bid < minLevel) sl = bid + minLevel;
         if(ask - tp < minLevel) tp = ask - minLevel;
      }
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
      bool success = false;
      if(isModify)
      {
         success = OrderModify(ticket, price, sl, tp, 0, clrNONE);
      }
      else
      {
         ticket = OrderSend(Symbol(), orderType, lot, price, 0, sl, tp, comment, MagicNumber, 0, clrNONE);
         success = (ticket > 0);
      }
      if(success)
         return(true);

      int err = GetLastError();
      if(err == ERR_INVALID_STOPS || err == ERR_INVALID_TRADE_PARAMETERS)
      {
         if(isModify)
         {
            if(OrderSelect(ticket, SELECT_BY_TICKET))
               AdjustStops(OrderType() == OP_BUY, sl, tp);
         }
         else
         {
            if(orderType == OP_BUY || orderType == OP_SELL)
               AdjustStops(orderType == OP_BUY, sl, tp);
            else
               AdjustPendingPrice(orderType, price);
         }
         continue;
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

void CloseTicket(int ticket, MoveCatcherSystem sys)
{
   if(OrderSelect(ticket, SELECT_BY_TICKET))
   {
      double lots = OrderLots();
      double price = (OrderType()==OP_BUY) ? Bid : Ask;
      LogEvent("DUPLICATE_CLOSE", sys, OrderOpenPrice(), OrderStopLoss(), OrderTakeProfit(), GetSpread(), lots);
      OrderClose(ticket, lots, price, 0, clrNONE);
   }
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
   datetime lastTime = lastCloseTime[idx];
   int tickets[]; datetime times[];
   int newTickets[];
   if(sys==SYSTEM_A) ArrayCopy(newTickets,lastTicketsA); else ArrayCopy(newTickets,lastTicketsB);
   datetime newLastTime = lastTime;
   for(int i=0;i<OrdersHistoryTotal();i++)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
      if(OrderMagicNumber()!=MagicNumber || OrderSymbol()!=Symbol()) continue;
      int type=OrderType(); if(type!=OP_BUY && type!=OP_SELL) continue;
      if(OrderComment()!=CommentIdentifier(sys)) continue;
      datetime ct=OrderCloseTime();
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
      if(!OrderSelect(tickets[i], SELECT_BY_TICKET, MODE_HISTORY)) continue;
      double closePrice = OrderClosePrice();
      double tp = OrderTakeProfit();
      double sl = OrderStopLoss();
      double tol = Point*0.5;
      bool isTP = (tp>0 && MathAbs(closePrice - tp) <= tol);
      bool isSL = (sl>0 && MathAbs(closePrice - sl) <= tol);
      if(isTP || isSL)
      {
         if(sys==SYSTEM_A) state_A.OnTrade(isTP); else state_B.OnTrade(isTP);
      }
   }
   lastCloseTime[idx] = newLastTime;
   if(sys==SYSTEM_A) ArrayCopy(lastTicketsA,newTickets); else ArrayCopy(lastTicketsB,newTickets);
}

// チケット保持
int positionTicket[2] = { -1, -1 };
int shadowTicket[2]   = { -1, -1 };
int refillTicket[2]   = { -1, -1 };
int ticketBuyLim      = -1;
int ticketSellLim     = -1;
int lastType[2]       = { OP_BUY, OP_BUY };
bool needResendOCO    = false; // 初期OCO再送フラグ

// 関数プロトタイプ
void HandleBExecution(int filledTicket);
int  FindPositions(MoveCatcherSystem sys, int &tickets[], datetime &times[]);
int  FindPosition(MoveCatcherSystem sys);
void PlaceShadowOrder(MoveCatcherSystem sys);
void ReEnterSameDirection(MoveCatcherSystem sys);
void ManageSystem(MoveCatcherSystem sys);
void CheckRefill();
void CorrectDuplicatePositions();
void CloseTicket(int ticket, MoveCatcherSystem sys);
void LogEvent(string reason, MoveCatcherSystem sys, double entry, double sl, double tp, double spread, double actualLot);
void AdjustStops(bool isBuy, double &sl, double &tp);
void AdjustPendingPrice(int orderType, double &price);
double GetSpread();

// 初期化
int OnInit()
{
   state_A.Init();
   state_B.Init();

   double actualLot_A = CalcLot(SYSTEM_A);

   double entryA = Ask;
   double slA = entryA - GridPips * Pip;
   double tpA = entryA + GridPips * Pip;
   AdjustStops(true, slA, tpA);
   if(RetryOrder(false, positionTicket[SYSTEM_A], OP_BUY, actualLot_A, entryA, slA, tpA, COMMENT_A))
   {
      lastType[SYSTEM_A] = OP_BUY;
      PlaceShadowOrder(SYSTEM_A);
      LogEvent("INIT", SYSTEM_A, entryA, slA, tpA, GetSpread(), actualLot_A);
   }

   double spread = GetSpread();
   if(MaxSpreadPips <= 0 || spread <= MaxSpreadPips)
   {
      double actualLot_B = CalcLot(SYSTEM_B);
      double buyPrice  = entryA - s * Pip;
      double sellPrice = entryA + s * Pip;
      AdjustPendingPrice(OP_BUYLIMIT, buyPrice);
      AdjustPendingPrice(OP_SELLLIMIT, sellPrice);
      double sl=0, tp=0;
      if(RetryOrder(false, ticketBuyLim, OP_BUYLIMIT, actualLot_B, buyPrice, sl, tp, COMMENT_B))
         LogEvent("INIT", SYSTEM_B, buyPrice, 0, 0, spread, actualLot_B);
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
               double actualLot_B = CalcLot(SYSTEM_B);
               double buyPrice  = entryA - s * Pip;
               double sellPrice = entryA + s * Pip;
               if(ticketBuyLim < 0)
               {
                  AdjustPendingPrice(OP_BUYLIMIT, buyPrice);
                  double sl=0, tp=0;
                  if(RetryOrder(false, ticketBuyLim, OP_BUYLIMIT, actualLot_B, buyPrice, sl, tp, COMMENT_B))
                     LogEvent("INIT", SYSTEM_B, buyPrice, 0, 0, spread, actualLot_B);
               }
               if(ticketSellLim < 0)
               {
                  AdjustPendingPrice(OP_SELLLIMIT, sellPrice);
                  double sl=0, tp=0;
                  if(RetryOrder(false, ticketSellLim, OP_SELLLIMIT, actualLot_B, sellPrice, sl, tp, COMMENT_B))
                     LogEvent("INIT", SYSTEM_B, sellPrice, 0, 0, spread, actualLot_B);
               }
               if(ticketBuyLim > 0 && ticketSellLim > 0)
                  needResendOCO = false;
            }
         }
      }
   }
   else
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

// 影指値を配置
void PlaceShadowOrder(MoveCatcherSystem sys)
{
   int idx = (int)sys;
   if(positionTicket[idx] < 0 || !OrderSelect(positionTicket[idx], SELECT_BY_TICKET))
      return;

    int type = OrderType();
   double entry = OrderOpenPrice();
   double actualLot = CalcLot(sys);
   double price = (type == OP_BUY) ? entry + GridPips * Pip : entry - GridPips * Pip;
   int orderType = (type == OP_BUY) ? OP_SELLLIMIT : OP_BUYLIMIT;

   if(shadowTicket[idx] > 0 && OrderSelect(shadowTicket[idx], SELECT_BY_TICKET))
      OrderDelete(shadowTicket[idx]);

   AdjustPendingPrice(orderType, price);
   double sl=0, tp=0;
   RetryOrder(false, shadowTicket[idx], orderType, actualLot, price, sl, tp, CommentIdentifier(sys));
}

// 同方向に成行再エントリ
void ReEnterSameDirection(MoveCatcherSystem sys)
{
   int idx = (int)sys;
   int type = lastType[idx];
   double actualLot = CalcLot(sys);
   double price = (type == OP_BUY) ? Ask : Bid;
   double sl = (type == OP_BUY) ? price - GridPips * Pip : price + GridPips * Pip;
   double tp = (type == OP_BUY) ? price + GridPips * Pip : price - GridPips * Pip;
   AdjustStops(type==OP_BUY, sl, tp);
   if(RetryOrder(false, positionTicket[idx], type, actualLot, price, sl, tp, CommentIdentifier(sys)))
   {
      LogEvent("SL_REENTRY", sys, price, sl, tp, GetSpread(), actualLot);
      PlaceShadowOrder(sys);
   }
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
         double sl = (lastType[idx]==OP_BUY) ? entry - GridPips * Pip : entry + GridPips * Pip;
         double tp = (lastType[idx]==OP_BUY) ? entry + GridPips * Pip : entry - GridPips * Pip;
         AdjustStops(lastType[idx]==OP_BUY, sl, tp);
         if(RetryOrder(true, current, 0, 0, entry, sl, tp, ""))
         {
            string reason;
            if(current == refillTicket[idx])
            {
               reason = "REFILL";
               refillTicket[idx] = -1;
            }
            else if(prevType != lastType[idx])
               reason = "TP_REV";
            else
               reason = "SL_REENTRY";
            LogEvent(reason, sys, entry, sl, tp, GetSpread(), OrderLots());
         }
      }
      PlaceShadowOrder(sys);
      return;
   }

   if(current > 0)
   {
      if(shadowTicket[idx] < 0 || !OrderSelect(shadowTicket[idx], SELECT_BY_TICKET))
         PlaceShadowOrder(sys);
      return;
   }

   if(positionTicket[idx] > 0)
   {
      positionTicket[idx] = -1;
      if(shadowTicket[idx] > 0 && OrderSelect(shadowTicket[idx], SELECT_BY_TICKET))
         OrderDelete(shadowTicket[idx]);
      shadowTicket[idx] = -1;
      ReEnterSameDirection(sys);
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
         double spread = GetSpread();
         if(MaxSpreadPips <= 0 || spread <= MaxSpreadPips)
         {
            double actualLot = CalcLot(SYSTEM_B);
            double priceNow = (Bid + Ask) / 2.0;
            double price;
            int orderType;
            if(priceNow >= entry)
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
   else if(!hasA && hasB && refillTicket[SYSTEM_A] < 0)
   {
      if(OrderSelect(posB, SELECT_BY_TICKET))
      {
         double entry = OrderOpenPrice();
         double spread = GetSpread();
         if(MaxSpreadPips <= 0 || spread <= MaxSpreadPips)
         {
            double actualLot = CalcLot(SYSTEM_A);
            double priceNow = (Bid + Ask) / 2.0;
            double price;
            int orderType;
            if(priceNow >= entry)
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
      if(ticketSellLim > 0 && OrderSelect(ticketSellLim, SELECT_BY_TICKET) && OrderType() == OP_SELLLIMIT)
      {
         LogEvent("OCO_CANCEL", SYSTEM_B, OrderOpenPrice(), 0, 0, GetSpread(), OrderLots());
         OrderDelete(ticketSellLim);
      }
      ticketSellLim = -1;
      ticketBuyLim  = -1; // 約定済みチケットをリセット
   }
   else if(filledTicket == ticketSellLim)
   {
      if(ticketBuyLim > 0 && OrderSelect(ticketBuyLim, SELECT_BY_TICKET) && OrderType() == OP_BUYLIMIT)
      {
         LogEvent("OCO_CANCEL", SYSTEM_B, OrderOpenPrice(), 0, 0, GetSpread(), OrderLots());
         OrderDelete(ticketBuyLim);
      }
      ticketBuyLim  = -1;
      ticketSellLim = -1; // 約定済みチケットをリセット
   }

   if(OrderSelect(filledTicket, SELECT_BY_TICKET))
   {
      double entry = OrderOpenPrice();
      double sl, tp;
      if(OrderType() == OP_BUY)
      {
         sl = entry - GridPips * Pip;
         tp = entry + GridPips * Pip;
      }
      else
      {
         sl = entry + GridPips * Pip;
         tp = entry - GridPips * Pip;
      }
      AdjustStops(OrderType()==OP_BUY, sl, tp);
      if(RetryOrder(true, filledTicket, 0, 0, entry, sl, tp, ""))
      {
         positionTicket[SYSTEM_B] = filledTicket;
         lastType[SYSTEM_B] = OrderType();
         LogEvent("OCO_HIT", SYSTEM_B, entry, sl, tp, GetSpread(), OrderLots());
         PlaceShadowOrder(SYSTEM_B);
      }
   }
}


