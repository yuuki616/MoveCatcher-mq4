#property strict
#property show_inputs

#include <DecompositionMonteCarloMM.mqh>

input double GridPips      = 100;     // TP/SL距離（pips）
input double BaseLot       = 0.10;    // 基準ロット
input double MaxSpreadPips = 2.0;     // 最大許容スプレッド（pips）
input int    MagicNumber   = 246810;  // マジックナンバー

// 内部変数
CDecompMC dmcA, dmcB;
double    Pip;
double    d;     // TP/SL距離（price）
double    s;     // 建値間隔（price）
datetime  lastHist = 0;

// ユーティリティ

double NormalizeLot(double lot)
{
   double step = MarketInfo(Symbol(), MODE_LOTSTEP);
   double min  = MarketInfo(Symbol(), MODE_MINLOT);
   double max  = MarketInfo(Symbol(), MODE_MAXLOT);
   lot = MathMax(min, MathMin(max, lot));
   int steps = (int)MathRound(lot/step);
   return(steps*step);
}

bool SpreadOK()
{
   if(MaxSpreadPips<=0) return(true);
   double spread = (Ask - Bid)/Pip;
   return(spread <= MaxSpreadPips);
}

int CountPositions(const string comment)
{
   int count=0;
   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber()!=MagicNumber) continue;
      if(OrderComment()!=comment) continue;
      if(OrderType()==OP_BUY || OrderType()==OP_SELL) count++;
   }
   return(count);
}

int CountPendings(const string comment)
{
   int count=0;
   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber()!=MagicNumber) continue;
      if(OrderComment()!=comment) continue;
      if(OrderType()!=OP_BUY && OrderType()!=OP_SELL) count++;
   }
   return(count);
}

void CancelPendings(const string comment)
{
   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber()!=MagicNumber) continue;
      if(OrderComment()!=comment) continue;
      if(OrderType()==OP_BUY || OrderType()==OP_SELL) continue;
      OrderDelete(OrderTicket());
   }
}

void SetTPSL(int ticket)
{
   if(!OrderSelect(ticket, SELECT_BY_TICKET)) return;
   if(OrderType()!=OP_BUY && OrderType()!=OP_SELL) return;
   if(OrderTakeProfit()!=0 || OrderStopLoss()!=0) return;
   double price = OrderOpenPrice();
   double tp, sl;
   if(OrderType()==OP_BUY){ tp = price + d; sl = price - d; }
   else                  { tp = price - d; sl = price + d; }
   OrderModify(ticket, price, sl, tp, 0);
}

void PlaceRefill(const string comment, bool longExist, double basePrice)
{
   if(!SpreadOK()) return;
   CDecompMC &dmc = (comment=="MoveCatcher_A") ? dmcA : dmcB;
   double lot = NormalizeLot(BaseLot * dmc.NextLot());
   double price = longExist ? basePrice + s : basePrice - s;
   int type = longExist ? OP_SELLLIMIT : OP_BUYLIMIT;
   OrderSend(Symbol(), type, lot, price, 0, 0, 0, comment, MagicNumber, 0, clrRed);
}

int OnInit()
{
   Pip = (_Digits==3 || _Digits==5) ? 10*_Point : _Point;
   d   = GridPips * Pip;
   s   = d/2.0;

   dmcA.Init();
   dmcB.Init();

   double lotA = NormalizeLot(BaseLot * dmcA.NextLot());
   double priceA = Ask;
   double tpA = priceA + d;
   double slA = priceA - d;
   int ticketA = OrderSend(Symbol(), OP_BUY, lotA, priceA, 0, slA, tpA, "MoveCatcher_A", MagicNumber, 0, clrBlue);
   if(ticketA<0) Print("Init order A failed: ",GetLastError());

   if(SpreadOK())
   {
      double lotB = NormalizeLot(BaseLot * dmcB.NextLot());
      double sellPrice = priceA + s;
      double buyPrice  = priceA - s;
      OrderSend(Symbol(), OP_SELLLIMIT, lotB, sellPrice, 0, 0, 0, "MoveCatcher_B", MagicNumber, 0, clrRed);
      OrderSend(Symbol(), OP_BUYLIMIT,  lotB, buyPrice,  0, 0, 0, "MoveCatcher_B", MagicNumber, 0, clrRed);
   }

   lastHist = TimeCurrent();
   return(INIT_SUCCEEDED);
}

void HandleClose(CDecompMC &dmc, const string comment, int prevType, bool win)
{
   dmc.OnTrade(win);
   double lot = NormalizeLot(BaseLot * dmc.NextLot());
   int type = prevType;
   if(win) type = (prevType==OP_BUY) ? OP_SELL : OP_BUY;
   double price = (type==OP_BUY) ? Ask : Bid;
   double tp = (type==OP_BUY) ? price + d : price - d;
   double sl = (type==OP_BUY) ? price - d : price + d;
   int ticket = OrderSend(Symbol(), type, lot, price, 0, sl, tp, comment, MagicNumber, 0, clrBlue);
   if(ticket<0) Print("Re-entry failed: ",GetLastError());
}

void ProcessClosed()
{
   int total = OrdersHistoryTotal();
   for(int i=total-1; i>=0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
      if(OrderMagicNumber()!=MagicNumber) continue;
      if(OrderCloseTime() <= lastHist) break;
      string comment = OrderComment();
      bool win = (OrderProfit() >= 0);
      int type = OrderType();
      if(comment=="MoveCatcher_A")
         HandleClose(dmcA, comment, type, win);
      else if(comment=="MoveCatcher_B")
         HandleClose(dmcB, comment, type, win);
   }
   lastHist = TimeCurrent();
}

void CheckPendings()
{
   // 片割れキャンセル & TP/SL設定
   int posA=0,posB=0;
   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber()!=MagicNumber) continue;
      string c = OrderComment();
      if(OrderType()==OP_BUY || OrderType()==OP_SELL)
      {
         if(c=="MoveCatcher_A") posA++;
         if(c=="MoveCatcher_B") posB++;
         SetTPSL(OrderTicket());
      }
   }

   // OCOキャンセル
   if(posA>0 && posB>0)
   {
      CancelPendings("MoveCatcher_A");
      CancelPendings("MoveCatcher_B");
   }
   else if(posA>0 && posB==0)
   {
      double priceA=0; bool longA=false;
      for(int i=OrdersTotal()-1;i>=0;i--){
         if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
         if(OrderMagicNumber()!=MagicNumber) continue;
         if(OrderComment()!="MoveCatcher_A") continue;
         priceA = OrderOpenPrice();
         longA  = (OrderType()==OP_BUY);
      }
      if(CountPendings("MoveCatcher_B")==0)
         PlaceRefill("MoveCatcher_B", longA, priceA);
   }
   else if(posA==0 && posB>0)
   {
      double priceB=0; bool longB=false;
      for(int i=OrdersTotal()-1;i>=0;i--){
         if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
         if(OrderMagicNumber()!=MagicNumber) continue;
         if(OrderComment()!="MoveCatcher_B") continue;
         priceB = OrderOpenPrice();
         longB  = (OrderType()==OP_BUY);
      }
      if(CountPendings("MoveCatcher_A")==0)
         PlaceRefill("MoveCatcher_A", longB, priceB);
   }
}

void OnTick()
{
   ProcessClosed();
   CheckPendings();
}

int OnDeinit(){return(0);}
