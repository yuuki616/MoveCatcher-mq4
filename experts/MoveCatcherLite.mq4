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
int ticketA       = -1;
int ticketBuyLim  = -1;
int ticketSellLim = -1;

// B成立処理プロトタイプ
void HandleBExecution(int filledTicket);

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

   ticketA = OrderSend(Symbol(), OP_BUY, actualLot_A, Ask, 0, slA, tpA, COMMENT_A, MagicNumber, 0, clrNONE);

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

   double lotFactorB = stateB.NextLot();
   double actualLot_B = BaseLot * lotFactorB;

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
   }
}


