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
CDecompMC stateA;
CDecompMC stateB;

// チケット保持
int positionTicket[2] = { -1, -1 };
int shadowTicket[2]   = { -1, -1 };
int ticketBuyLim      = -1;
int ticketSellLim     = -1;
int lastType[2];

// 関数プロトタイプ
void HandleBExecution(int filledTicket);
int  FindPosition(MoveCatcherSystem sys);
void PlaceShadowOrder(MoveCatcherSystem sys);
void ReEnterSameDirection(MoveCatcherSystem sys);
void ManageSystem(MoveCatcherSystem sys);

// 初期化
int OnInit()
{
   stateA.Init();
   stateB.Init();

   double lotFactorA = stateA.NextLot();
   double actualLot_A = NormalizeDouble(BaseLot * lotFactorA, 2);

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
      double lotFactorB = stateB.NextLot();
      double actualLot_B = NormalizeDouble(BaseLot * lotFactorB, 2);
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
   if(ticketBuyLim > 0 && OrderSelect(ticketBuyLim, SELECT_BY_TICKET))
   {
      if(OrderType() == OP_BUY)
         HandleBExecution(ticketBuyLim);
   }

   if(ticketSellLim > 0 && OrderSelect(ticketSellLim, SELECT_BY_TICKET))
   {
      if(OrderType() == OP_SELL)
         HandleBExecution(ticketSellLim);
   }

   ManageSystem(SYSTEM_A);
   ManageSystem(SYSTEM_B);
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
   double lotFactor = (sys==SYSTEM_A) ? stateA.NextLot() : stateB.NextLot();
   double actualLot = NormalizeDouble(BaseLot * lotFactor, 2);
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
   double lotFactor = (sys==SYSTEM_A) ? stateA.NextLot() : stateB.NextLot();
   double actualLot = NormalizeDouble(BaseLot * lotFactor, 2);
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
      ReEnterSameDirection(sys);
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


