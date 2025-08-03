#property strict

#include <DecompositionMonteCarloMM.mqh>

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
input double GridPips          = 100;   // TP/SL distance (pips)
input double EpsilonPips       = 1.0;   // Tolerance width (pips)
input double MaxSpreadPips     = 2.0;   // Max spread when placing orders
input bool   UseProtectedLimit = true;  // Use slippage-protected market orders after SL
input double SlippagePips      = 1.0;   // Maximum slippage for market orders
input bool   UseDistanceBand   = false; // Filter by distance band before ordering
input double MinDistancePips   = 50;    // Minimum distance (pips)
input double MaxDistancePips   = 55;    // Maximum distance (pips)
input bool   UseTickSnap       = false; // Enable tick snap reset
input int    SnapCooldownBars  = 2;     // Cooldown for tick snap (bars)
input double BaseLot           = 0.10;  // Base lot size (0.01 step)
input double MaxLot            = 1.50;  // User-defined maximum lot (0.01 step)
input int    MagicNumber       = 246810;// Magic number for order identification

// Derived values
double s;   // Half grid distance

CDecompMC stateA; // DMCMM state for system A
CDecompMC stateB; // DMCMM state for system B

enum SystemState { Alive, Missing, MissingRecovered, None };
SystemState state_A = None;
SystemState state_B = None;

bool IsStep(const double value,const double step)
{
   double scaled = value/step;
   return(MathAbs(scaled - MathRound(scaled)) < 1e-8);
}

double Pip()
{
   return((Digits == 3 || Digits == 5) ? 10 * Point : Point);
}

double PipsToPrice(const double p)
{
   return(p * Pip());
}

double PriceToPips(const double priceDiff)
{
   return(priceDiff / Pip());
}

double NormalizeLot(const double lotCandidate)
{
   double minLot  = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot  = MarketInfo(Symbol(), MODE_MAXLOT);
   double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);

   double lot = lotCandidate;
   if(lotStep > 0)
      lot = MathRound(lot / lotStep) * lotStep;

   if(lot < minLot)
      lot = minLot;
   if(lot > maxLot)
      lot = maxLot;

   return(lot);
}

//+------------------------------------------------------------------+
//| Check spread and optional distance band before placing orders    |
//| checkSpread=true  -> also verify spread                          |
//+------------------------------------------------------------------+
bool CanPlace(const bool checkSpread)
{
   if(checkSpread)
   {
      double spread = PriceToPips(Ask - Bid);
      if(spread > MaxSpreadPips)
      {
         PrintFormat("Spread %.1f exceeds MaxSpreadPips %.1f", spread, MaxSpreadPips);
         return(false);
      }
   }

   if(UseDistanceBand)
   {
      double dist = PriceToPips(MathAbs(Ask - Bid));
      if(dist < MinDistancePips || dist > MaxDistancePips)
      {
         PrintFormat("Distance %.1f outside band [%.1f, %.1f]", dist, MinDistancePips, MaxDistancePips);
         return(false);
      }
   }

   return(true);
}

//+------------------------------------------------------------------+
//| Calculate actual lot based on system and DMCMM state             |
//+------------------------------------------------------------------+
double CalcLot(const string system,string &seq)
{
   CDecompMC *state = NULL;
   if(system == "A")
      state = &stateA;
   else if(system == "B")
      state = &stateB;
   else
   {
      seq = "";
      return(0.0);
   }

   double lotFactor    = state.NextLot();
   seq = "(" + state.Seq() + ")";
   double lotCandidate = BaseLot * lotFactor;

   if(lotCandidate > MaxLot)
   {
      state.Init();
      PrintFormat("LOT_RESET: system=%s",system);
      lotFactor    = state.NextLot();
      seq          = "(" + state.Seq() + ")";
      lotCandidate = BaseLot * lotFactor;
   }

   double lotActual = MathMin(lotCandidate, MaxLot);
   return(NormalizeLot(lotActual));
}

//+------------------------------------------------------------------+
//| Make comment string from system and sequence                     |
//+------------------------------------------------------------------+
string MakeComment(const string system,const string seq)
{
   string comment;
   StringConcatenate(comment,"MoveCatcher_",system,"_",seq);
   return(comment);
}

//+------------------------------------------------------------------+
//| Parse comment into system and sequence                           |
//| Returns true on success                                          |
//+------------------------------------------------------------------+
bool ParseComment(const string comment,string &system,string &seq)
{
   system="";
   seq="";

   string prefix="MoveCatcher_";
   int prefixLen=StringLen(prefix);
   if(StringSubstr(comment,0,prefixLen)!=prefix)
      return(false);

   int pos=StringFind(comment,"_",prefixLen);
   if(pos<0)
      return(false);

   system=StringSubstr(comment,prefixLen,pos-prefixLen);
   seq=StringSubstr(comment,pos+1);

   if(system!="A" && system!="B")
   {
      system="";
      seq="";
      return(false);
   }

   return(true);
}

SystemState UpdateState(const SystemState prev,const bool exists)
{
   if(exists)
   {
      if(prev == Missing)
         return(MissingRecovered);
      return(Alive);
   }
   if(prev == Alive || prev == MissingRecovered)
      return(Missing);
   return(None);
}

//+------------------------------------------------------------------+
//| Find existing shadow pending order for a position                |
//+------------------------------------------------------------------+
bool FindShadowPending(const string system,const double entry,const bool isBuy,int &ticket)
{
   double target = isBuy ? entry + PipsToPrice(GridPips)
                         : entry - PipsToPrice(GridPips);
   double tol = Point * 0.5;
   for(int i = OrdersTotal()-1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderMagicNumber() != MagicNumber || OrderSymbol() != Symbol())
         continue;
      int type = OrderType();
      if(type != OP_BUYLIMIT && type != OP_SELLLIMIT)
         continue;
      string sys, seq;
      if(!ParseComment(OrderComment(), sys, seq))
         continue;
      if(sys != system)
         continue;
      if((isBuy && type == OP_SELLLIMIT) || (!isBuy && type == OP_BUYLIMIT))
      {
         if(MathAbs(OrderOpenPrice() - target) <= tol)
         {
            ticket = OrderTicket();
            return(true);
         }
      }
   }
   ticket = -1;
   return(false);
}

//+------------------------------------------------------------------+
//| Ensure TP/SL are set for a position                              |
//+------------------------------------------------------------------+
void EnsureTPSL(const int ticket)
{
   if(!OrderSelect(ticket, SELECT_BY_TICKET))
      return;
   double entry = OrderOpenPrice();
   double desiredSL, desiredTP;
   if(OrderType() == OP_BUY)
   {
      desiredSL = entry - PipsToPrice(GridPips);
      desiredTP = entry + PipsToPrice(GridPips);
   }
   else
   {
      desiredSL = entry + PipsToPrice(GridPips);
      desiredTP = entry - PipsToPrice(GridPips);
   }
   if(OrderStopLoss() == 0 || OrderTakeProfit() == 0)
   {
      if(!OrderModify(ticket, entry, desiredSL, desiredTP, 0, clrNONE))
         PrintFormat("EnsureTPSL: failed to set TP/SL for ticket %d err=%d", ticket, GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Ensure shadow limit order exists for a position                   |
//+------------------------------------------------------------------+
void EnsureShadowOrder(const int ticket,const string system)
{
   if(!OrderSelect(ticket, SELECT_BY_TICKET))
      return;
   double entry = OrderOpenPrice();
   bool   isBuy = (OrderType() == OP_BUY);
   int    pendTicket;
   if(FindShadowPending(system, entry, isBuy, pendTicket))
      return; // already exists
   string seq;
   double lot = CalcLot(system, seq);
   if(lot <= 0)
      return;
   double price = isBuy ? entry + PipsToPrice(GridPips)
                        : entry - PipsToPrice(GridPips);
   int type = isBuy ? OP_SELLLIMIT : OP_BUYLIMIT;
   string comment = MakeComment(system, seq);
   int tk = OrderSend(Symbol(), type, lot, price, 0, 0, 0, comment, MagicNumber, 0, clrNONE);
   if(tk < 0)
      PrintFormat("EnsureShadowOrder: failed to place shadow order for %s err=%d", system, GetLastError());
}

//+------------------------------------------------------------------+
//| Delete all pending orders for specified system                    |
//+------------------------------------------------------------------+
void DeletePendings(const string system)
{
   for(int i = OrdersTotal()-1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderMagicNumber() != MagicNumber || OrderSymbol() != Symbol())
         continue;
      int type = OrderType();
      if(type != OP_BUYLIMIT && type != OP_SELLLIMIT && type != OP_BUYSTOP && type != OP_SELLSTOP)
         continue;
      string sys, seq;
      if(!ParseComment(OrderComment(), sys, seq))
         continue;
      if(sys != system)
         continue;
      int tk = OrderTicket();
      if(!OrderDelete(tk))
         PrintFormat("DeletePendings: failed to delete %d err=%d", tk, GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Re-enter position after SL according to UseProtectedLimit         |
//+------------------------------------------------------------------+
void RecoverAfterSL(const string system)
{
   RefreshRates();
   DeletePendings(system);

   int lastType = -1;
   for(int i = OrdersHistoryTotal()-1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY))
         continue;
      if(OrderMagicNumber() != MagicNumber || OrderSymbol() != Symbol())
         continue;
      string sys, seq;
      if(!ParseComment(OrderComment(), sys, seq))
         continue;
      if(sys != system)
         continue;
      int type = OrderType();
      if(type == OP_BUY || type == OP_SELL)
      {
         lastType = type;
         break;
      }
   }
   if(lastType == -1)
      return;

   string seq;
   double lot = CalcLot(system, seq);
   if(lot <= 0)
      return;

   bool   isBuy    = (lastType == OP_BUY);
   int    slippage = UseProtectedLimit ? (int)(SlippagePips * Pip() / Point) : 0;
   double price    = isBuy ? Ask : Bid;
   double sl       = isBuy ? price - PipsToPrice(GridPips) : price + PipsToPrice(GridPips);
   double tp       = isBuy ? price + PipsToPrice(GridPips) : price - PipsToPrice(GridPips);
   string comment  = MakeComment(system, seq);
   int ticket      = OrderSend(Symbol(), isBuy ? OP_BUY : OP_SELL, lot, price,
                               slippage, sl, tp, comment, MagicNumber, 0, clrNONE);
   if(ticket < 0)
   {
      PrintFormat("RecoverAfterSL: failed to reopen %s err=%d", system, GetLastError());
      return;
   }

   EnsureShadowOrder(ticket, system);

   if(system == "A")
      state_A = Alive;
   else if(system == "B")
      state_B = Alive;
}

//+------------------------------------------------------------------+
//| Place initial market order for system A and OCO limits for B     |
//+------------------------------------------------------------------+
void InitStrategy()
{
   RefreshRates();

   //---- system A market order
   string seqA; double lotA = CalcLot("A", seqA);
   if(lotA <= 0) return;

   bool isBuy = (MathRand() % 2) == 0;
   int    slippage = (int)(SlippagePips * Pip() / Point);
   double price    = isBuy ? Ask : Bid;
   double entrySL, entryTP;
   if(isBuy)
   {
      entrySL = price - PipsToPrice(GridPips);
      entryTP = price + PipsToPrice(GridPips);
   }
   else
   {
      entrySL = price + PipsToPrice(GridPips);
      entryTP = price - PipsToPrice(GridPips);
   }

   string commentA = MakeComment("A", seqA);
   int ticketA = OrderSend(Symbol(), isBuy ? OP_BUY : OP_SELL, lotA, price,
                           slippage, entrySL, entryTP, commentA, MagicNumber, 0, clrNONE);
   if(ticketA < 0)
   {
      PrintFormat("InitStrategy: failed to place system A order, err=%d", GetLastError());
      return;
   }

   if(!OrderSelect(ticketA, SELECT_BY_TICKET))
      return;
   double entryPrice = OrderOpenPrice();

   EnsureShadowOrder(ticketA, "A");

   //---- system B OCO pending orders
   if(!CanPlace(true))
      return;

   string seqB; double lotB = CalcLot("B", seqB);
   if(lotB <= 0) return;
   string commentB = MakeComment("B", seqB);

   double priceSell = entryPrice + PipsToPrice(s);
   double priceBuy  = entryPrice - PipsToPrice(s);

   int ticketSell = OrderSend(Symbol(), OP_SELLLIMIT, lotB, priceSell,
                              0, 0, 0, commentB, MagicNumber, 0, clrNONE);
   if(ticketSell < 0)
      PrintFormat("InitStrategy: failed to place SellLimit, err=%d", GetLastError());

   int ticketBuy = OrderSend(Symbol(), OP_BUYLIMIT, lotB, priceBuy,
                             0, 0, 0, commentB, MagicNumber, 0, clrNONE);
   if(ticketBuy < 0)
      PrintFormat("InitStrategy: failed to place BuyLimit, err=%d", GetLastError());
}

//+------------------------------------------------------------------+
//| Detect filled OCO and handle cancellation and TP/SL attachment    |
//+------------------------------------------------------------------+
void HandleOCODetection()
{
   int bPosTicket = -1;

   // find existing B position if any
   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() != MagicNumber || OrderSymbol() != Symbol()) continue;
      string sys, seq; if(!ParseComment(OrderComment(), sys, seq)) continue;
      if(sys=="B" && (OrderType()==OP_BUY || OrderType()==OP_SELL))
      {
         bPosTicket = OrderTicket();
         break;
      }
   }

   if(bPosTicket==-1)
      return; // no B position

   // remove remaining B pending orders
   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() != MagicNumber || OrderSymbol() != Symbol()) continue;
      string sys, seq; if(!ParseComment(OrderComment(), sys, seq)) continue;
      if(sys=="B" && (OrderType()==OP_BUYLIMIT || OrderType()==OP_SELLLIMIT ||
                       OrderType()==OP_BUYSTOP || OrderType()==OP_SELLSTOP))
      {
         int delTicket = OrderTicket();
         if(!OrderDelete(delTicket))
            PrintFormat("Failed to delete pending order %d err=%d", delTicket, GetLastError());
      }
   }

   // attach TP/SL if not already
   if(!OrderSelect(bPosTicket, SELECT_BY_TICKET))
      return;

   if(OrderStopLoss()==0 || OrderTakeProfit()==0)
   {
      double entry = OrderOpenPrice();
      double sl, tp;
      if(OrderType()==OP_BUY)
      {
         sl = entry - PipsToPrice(GridPips);
         tp = entry + PipsToPrice(GridPips);
      }
      else
      {
         sl = entry + PipsToPrice(GridPips);
         tp = entry - PipsToPrice(GridPips);
      }
      if(!OrderModify(bPosTicket, entry, sl, tp, 0, clrNONE))
         PrintFormat("Failed to set TP/SL for ticket %d err=%d", bPosTicket, GetLastError());
   }

   EnsureShadowOrder(bPosTicket, "B");
}

int OnInit()
{
   if(GridPips <= 0)
   {
      Print("GridPips must be greater than 0");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(EpsilonPips < 0)
   {
      Print("EpsilonPips must be non-negative");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(MaxSpreadPips < 0)
   {
      Print("MaxSpreadPips must be non-negative");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(SlippagePips < 0)
   {
      Print("SlippagePips must be non-negative");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(UseDistanceBand)
   {
      if(MinDistancePips < 0 || MaxDistancePips < MinDistancePips)
      {
         Print("Distance band parameters are invalid");
         return(INIT_PARAMETERS_INCORRECT);
      }
   }
   if(BaseLot <= 0 || !IsStep(BaseLot,0.01))
   {
      Print("BaseLot must be positive and in 0.01 increments");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(MaxLot <= 0 || !IsStep(MaxLot,0.01))
   {
      Print("MaxLot must be positive and in 0.01 increments");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(MaxLot < BaseLot)
   {
      Print("MaxLot must be greater than or equal to BaseLot");
      return(INIT_PARAMETERS_INCORRECT);
   }

   s   = GridPips / 2.0;

   stateA.Init();
   stateB.Init();

   string gvA = "MoveCatcher_state_A";
   string gvB = "MoveCatcher_state_B";
   if(GlobalVariableCheck(gvA))
      state_A = (SystemState)MathRound(GlobalVariableGet(gvA));
   else
      state_A = None;
   if(GlobalVariableCheck(gvB))
      state_B = (SystemState)MathRound(GlobalVariableGet(gvB));
   else
      state_B = None;

   MathSrand(GetTickCount());
   InitStrategy();

   return(INIT_SUCCEEDED);
}

void OnTick()
{
   HandleOCODetection();

   bool hasA = false;
   bool hasB = false;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderMagicNumber() != MagicNumber || OrderSymbol() != Symbol())
         continue;
      string system, seq;
      if(!ParseComment(OrderComment(), system, seq))
         continue;
      int type = OrderType();
      if(type == OP_BUY || type == OP_SELL)
      {
         if(system == "A")
            hasA = true;
         else if(system == "B")
            hasB = true;

         EnsureTPSL(OrderTicket());
         EnsureShadowOrder(OrderTicket(), system);
      }
   }

   state_A = UpdateState(state_A, hasA);
   state_B = UpdateState(state_B, hasB);

   if(state_A == Missing)
      RecoverAfterSL("A");
   if(state_B == Missing)
      RecoverAfterSL("B");
}

void OnDeinit(const int reason)
{
   string gvA = "MoveCatcher_state_A";
   string gvB = "MoveCatcher_state_B";
   GlobalVariableSet(gvA, state_A);
   GlobalVariableSet(gvB, state_B);
}

