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
   RefreshRates();
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
      int type = OrderType();
      if(type==OP_BUYLIMIT || type==OP_SELLLIMIT || type==OP_BUYSTOP || type==OP_SELLSTOP)
         count++;
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
      int type = OrderType();
      if(type==OP_BUYLIMIT || type==OP_SELLLIMIT || type==OP_BUYSTOP || type==OP_SELLSTOP)
      {
         if(!OrderDelete(OrderTicket()))
            Print("OrderDelete failed: ",GetLastError());
      }
   }
}

void CloseExtraPositions(const string comment)
{
   int tickets[];
   for(int i=0; i<OrdersTotal(); i++)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber()!=MagicNumber) continue;
      if(OrderComment()!=comment) continue;
      int type = OrderType();
      if(type==OP_BUY || type==OP_SELL)
      {
         int n = ArraySize(tickets);
         ArrayResize(tickets, n+1);
         tickets[n] = OrderTicket();
      }
   }
   for(int i=ArraySize(tickets)-1; i>=1; i--)
   {
      int ticket = tickets[i];
      if(OrderSelect(ticket, SELECT_BY_TICKET))
      {
         RefreshRates();
         double price = (OrderType()==OP_BUY)?Bid:Ask;
         if(!OrderClose(ticket, OrderLots(), price, 0))
            Print("OrderClose failed: ",GetLastError());
      }
   }
}

void SetTPSL(int ticket)
{
   if(!OrderSelect(ticket, SELECT_BY_TICKET)) return;
   int type = OrderType();
   if(type!=OP_BUY && type!=OP_SELL) return;
   double price = NormalizeDouble(OrderOpenPrice(), _Digits);
   double tp = (type==OP_BUY) ? price + d : price - d;
   double sl = (type==OP_BUY) ? price - d : price + d;
   tp = NormalizeDouble(tp, _Digits);
   sl = NormalizeDouble(sl, _Digits);
   if(MathAbs(OrderTakeProfit()-tp) > Pip/2.0 || MathAbs(OrderStopLoss()-sl) > Pip/2.0)
   {
      if(!OrderModify(ticket, price, sl, tp, 0))
         Print("OrderModify failed: ",GetLastError());
   }
}

void PlaceRefill(const string comment, bool longExist, double basePrice)
{
   if(!SpreadOK()) return;
   double lot   = NormalizeLot(
      BaseLot * ((comment=="MoveCatcher_A") ? dmcA.NextLot() : dmcB.NextLot())
   );
   double price = longExist ? basePrice + s : basePrice - s;
   price = NormalizeDouble(price, _Digits);
   int type = longExist ? OP_SELLLIMIT : OP_BUYLIMIT;
   RefreshRates();
   int ticket = OrderSend(Symbol(), type, lot, price, 0, 0, 0, comment, MagicNumber, 0, clrRed);
   if(ticket<0)
      Print("Refill order failed: ",GetLastError());
}

int OnInit()
{
   Pip = (_Digits==3 || _Digits==5) ? 10*_Point : _Point;
   d   = GridPips * Pip;
   s   = d/2.0;

   dmcA.Init();
   dmcB.Init();

   RefreshRates();
   double lotA   = NormalizeLot(BaseLot * dmcA.NextLot());
   double priceA = NormalizeDouble(Ask, _Digits);
   double tpA    = NormalizeDouble(priceA + d, _Digits);
   double slA    = NormalizeDouble(priceA - d, _Digits);
   int ticketA = OrderSend(Symbol(), OP_BUY, lotA, priceA, 0, slA, tpA, "MoveCatcher_A", MagicNumber, 0, clrBlue);
   if(ticketA<0) Print("Init order A failed: ",GetLastError());

   if(SpreadOK())
   {
      double lotB      = NormalizeLot(BaseLot * dmcB.NextLot());
      double sellPrice = NormalizeDouble(priceA + s, _Digits);
      double buyPrice  = NormalizeDouble(priceA - s, _Digits);
      int sellTicket = OrderSend(Symbol(), OP_SELLLIMIT, lotB, sellPrice, 0, 0, 0, "MoveCatcher_B", MagicNumber, 0, clrRed);
      if(sellTicket<0) Print("Init order B sell failed: ",GetLastError());
      int buyTicket  = OrderSend(Symbol(), OP_BUYLIMIT,  lotB, buyPrice,  0, 0, 0, "MoveCatcher_B", MagicNumber, 0, clrRed);
      if(buyTicket<0)  Print("Init order B buy failed: ",GetLastError());
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
   RefreshRates();
   double price = (type==OP_BUY) ? Ask : Bid;
   price = NormalizeDouble(price, _Digits);
   double tp = (type==OP_BUY) ? price + d : price - d;
   double sl = (type==OP_BUY) ? price - d : price + d;
   tp = NormalizeDouble(tp, _Digits);
   sl = NormalizeDouble(sl, _Digits);
   int ticket = OrderSend(Symbol(), type, lot, price, 0, sl, tp, comment, MagicNumber, 0, clrBlue);
   if(ticket<0) Print("Re-entry failed: ",GetLastError());
}

void ProcessClosed()
{
   int total = OrdersHistoryTotal();
   datetime latest = lastHist;
   for(int i=total-1; i>=0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
      if(OrderMagicNumber()!=MagicNumber) continue;
      int type = OrderType();
      if(type!=OP_BUY && type!=OP_SELL) continue;      // 未約定指値の履歴を除外
      datetime ct = OrderCloseTime();
      if(ct <= lastHist) break;
      string comment = OrderComment();

      double closePrice = OrderClosePrice();
      double tp = OrderTakeProfit();
      double sl = OrderStopLoss();
      bool win = false;
      if(tp>0 && MathAbs(closePrice - tp) <= Pip/2.0) win = true;
      else if(sl>0 && MathAbs(closePrice - sl) <= Pip/2.0) win = false;
      else win = (OrderProfit() >= 0);

      if(comment=="MoveCatcher_A")
         HandleClose(dmcA, comment, type, win);
      else if(comment=="MoveCatcher_B")
         HandleClose(dmcB, comment, type, win);
      if(ct > latest) latest = ct;
   }
   lastHist = latest;
}

void CheckPendings()
{
   // 同系統多重ポジションの整理
   CloseExtraPositions("MoveCatcher_A");
   CloseExtraPositions("MoveCatcher_B");

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

void OnDeinit(const int reason)
{
   // 特に後処理は不要
}
