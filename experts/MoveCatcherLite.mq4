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
int lastType[2];

// 関数プロトタイプ
void HandleBExecution(int filledTicket);
int  FindPosition(MoveCatcherSystem sys);
void PlaceShadowOrder(MoveCatcherSystem sys);
void ReEnterSameDirection(MoveCatcherSystem sys);
void ManageSystem(MoveCatcherSystem sys);
void CheckRefill();

// 初期化
int OnInit()
{
   state_A.Init();
   state_B.Init();

   double actualLot_A = CalcLot(SYSTEM_A);

   double entryA = Ask;
   double slA = entryA - GridPips * Pip;
   double tpA = entryA + GridPips * Pip;

   positionTicket[SYSTEM_A] = OrderSend(Symbol(), OP_BUY, actualLot_A, Ask, 0, slA, tpA, COMMENT_A, MagicNumber, 0, clrNONE);
   if(positionTicket[SYSTEM_A] > 0)
   {
      lastType[SYSTEM_A] = OP_BUY;
      PlaceShadowOrder(SYSTEM_A);
   }

   double spread = (Ask - Bid) / Pip;
   if(MaxSpreadPips <= 0 || spread <= MaxSpreadPips)
   {
      double actualLot_B = CalcLot(SYSTEM_B);
      double buyPrice  = entryA - s * Pip;
      double sellPrice = entryA + s * Pip;
      ticketBuyLim  = OrderSend(Symbol(), OP_BUYLIMIT,  actualLot_B, buyPrice,  0, 0, 0, COMMENT_B, MagicNumber, 0, clrNONE);
      ticketSellLim = OrderSend(Symbol(), OP_SELLLIMIT, actualLot_B, sellPrice, 0, 0, 0, COMMENT_B, MagicNumber, 0, clrNONE);
   }

   return(INIT_SUCCEEDED);
}

// ティック処理
void OnTick()
{
   ProcessClosedTrades(SYSTEM_A);
   ProcessClosedTrades(SYSTEM_B);

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
   CheckRefill();
}

// ポジション検索
int FindPosition(MoveCatcherSystem sys)
{
   for(int i=0; i<OrdersTotal(); i++)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderMagicNumber() == MagicNumber && OrderSymbol() == Symbol() && OrderComment() == CommentIdentifier(sys))
         {
            if(OrderType() == OP_BUY || OrderType() == OP_SELL)
               return OrderTicket();
         }
      }
   }
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

   shadowTicket[idx] = OrderSend(Symbol(), orderType, actualLot, price, 0, 0, 0, CommentIdentifier(sys), MagicNumber, 0, clrNONE);
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

   positionTicket[idx] = OrderSend(Symbol(), type, actualLot, price, 0, sl, tp, CommentIdentifier(sys), MagicNumber, 0, clrNONE);
   if(positionTicket[idx] > 0)
      PlaceShadowOrder(sys);
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
         lastType[idx] = OrderType();
         double entry = OrderOpenPrice();
         double sl = (lastType[idx]==OP_BUY) ? entry - GridPips * Pip : entry + GridPips * Pip;
         double tp = (lastType[idx]==OP_BUY) ? entry + GridPips * Pip : entry - GridPips * Pip;
         OrderModify(current, entry, sl, tp, 0, clrNONE);
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
      if(sys == SYSTEM_A)
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
         double spread = (Ask - Bid) / Pip;
           if(MaxSpreadPips <= 0 || spread <= MaxSpreadPips)
           {
              double actualLot = CalcLot(SYSTEM_B);
              double priceNow = (Bid + Ask) / 2.0;
            double price;
            int orderType;
            if(priceNow >= entry)
            {
               price = entry - s * Pip;
               orderType = OP_BUYLIMIT;
            }
            else
            {
               price = entry + s * Pip;
               orderType = OP_SELLLIMIT;
            }
            refillTicket[SYSTEM_B] = OrderSend(Symbol(), orderType, actualLot, price, 0, 0, 0, COMMENT_B, MagicNumber, 0, clrNONE);
         }
      }
   }
   else if(!hasA && hasB && refillTicket[SYSTEM_A] < 0)
   {
      if(OrderSelect(posB, SELECT_BY_TICKET))
      {
         double entry = OrderOpenPrice();
         double spread = (Ask - Bid) / Pip;
           if(MaxSpreadPips <= 0 || spread <= MaxSpreadPips)
           {
              double actualLot = CalcLot(SYSTEM_A);
              double priceNow = (Bid + Ask) / 2.0;
            double price;
            int orderType;
            if(priceNow >= entry)
            {
               price = entry - s * Pip;
               orderType = OP_BUYLIMIT;
            }
            else
            {
               price = entry + s * Pip;
               orderType = OP_SELLLIMIT;
            }
            refillTicket[SYSTEM_A] = OrderSend(Symbol(), orderType, actualLot, price, 0, 0, 0, COMMENT_A, MagicNumber, 0, clrNONE);
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
         OrderDelete(ticketSellLim);
      ticketSellLim = -1;
   }
   else if(filledTicket == ticketSellLim)
   {
      if(ticketBuyLim > 0 && OrderSelect(ticketBuyLim, SELECT_BY_TICKET) && OrderType() == OP_BUYLIMIT)
         OrderDelete(ticketBuyLim);
      ticketBuyLim = -1;
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
      OrderModify(filledTicket, entry, sl, tp, 0, clrNONE);

      positionTicket[SYSTEM_B] = filledTicket;
      lastType[SYSTEM_B] = OrderType();
      PlaceShadowOrder(SYSTEM_B);
   }
}


