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

int lastSnapBar = -1; // last bar index when tick snap reset occurred

datetime lastCloseTimeA = 0; // last processed close time for system A
datetime lastCloseTimeB = 0; // last processed close time for system B

int retryTicketA = -1; // ticket to retry TP/SL setting for system A
int retryTicketB = -1; // ticket to retry TP/SL setting for system B

struct LogRecord
{
   datetime Time;
   string   Symbol;
   string   System;
   string   Reason;
   double   Spread;
   double   Dist;
   double   GridPips;
   double   s;
   double   lotFactor;
   double   BaseLot;
   double   MaxLot;
   double   actualLot;
   string   seqStr;
   string   CommentTag;
   int      Magic;
   string   OrderType;
   double   EntryPrice;
   double   SL;
   double   TP;
   int      ErrorCode;
};

string OrderTypeToStr(const int type)
{
   if(type == OP_BUY)      return("BUY");
   if(type == OP_SELL)     return("SELL");
   if(type == OP_BUYLIMIT) return("BUYLIMIT");
   if(type == OP_SELLLIMIT)return("SELLLIMIT");
   if(type == OP_BUYSTOP)  return("BUYSTOP");
   if(type == OP_SELLSTOP) return("SELLSTOP");
   return("UNKNOWN");
}

void WriteLog(const LogRecord &rec)
{
   int handle = FileOpen("MoveCatcher.log", FILE_CSV|FILE_WRITE|FILE_READ|FILE_APPEND);
   string timeStr = TimeToString(rec.Time, TIME_DATE|TIME_SECONDS);
   if(handle != INVALID_HANDLE)
   {
      FileWrite(handle,
         timeStr,
         rec.Symbol,
         rec.System,
         rec.Reason,
         DoubleToString(rec.Spread,1),
         DoubleToString(rec.Dist,1),
         DoubleToString(rec.GridPips,1),
         DoubleToString(rec.s,1),
         DoubleToString(rec.lotFactor,2),
         DoubleToString(rec.BaseLot,2),
         DoubleToString(rec.MaxLot,2),
         DoubleToString(rec.actualLot,2),
         rec.seqStr,
         rec.CommentTag,
         rec.Magic,
         rec.OrderType,
         DoubleToString(rec.EntryPrice,Digits),
         DoubleToString(rec.SL,Digits),
         DoubleToString(rec.TP,Digits),
         rec.ErrorCode);
      FileClose(handle);
   }
   PrintFormat("LOG %s,%s,%s,%s,%.1f,%.1f,%.1f,%.1f,%.2f,%.2f,%.2f,%.2f,%s,%s,%d,%s,%.5f,%.5f,%.5f,%d",
               timeStr,
               rec.Symbol,
               rec.System,
               rec.Reason,
               rec.Spread,
               rec.Dist,
               rec.GridPips,
               rec.s,
               rec.lotFactor,
               rec.BaseLot,
               rec.MaxLot,
               rec.actualLot,
               rec.seqStr,
               rec.CommentTag,
               rec.Magic,
               rec.OrderType,
               rec.EntryPrice,
               rec.SL,
               rec.TP,
               rec.ErrorCode);
}

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

bool SaveDMCState(const string system,const CDecompMC &state,int &err)
{
   err=0; bool ok=true;
   string data=state.Serialize();
   string parts[]; int cnt=StringSplit(data,'|',parts);
   if(cnt==3)
   {
      int stock=(int)StringToInteger(parts[0]);
      int streak=(int)StringToInteger(parts[1]);
      string seqParts[]; int n=StringSplit(parts[2],',',seqParts);

      string prefix="MoveCatcher_"+system+"_";
      ResetLastError(); GlobalVariableSet(prefix+"stock",stock); int e=GetLastError(); if(e!=0){if(err==0)err=e; ok=false;}
      ResetLastError(); GlobalVariableSet(prefix+"streak",streak); e=GetLastError(); if(e!=0){if(err==0)err=e; ok=false;}
      ResetLastError(); GlobalVariableSet(prefix+"seq_size",n); e=GetLastError(); if(e!=0){if(err==0)err=e; ok=false;}
      for(int i=0;i<n;i++)
      {
         string name=prefix+"seq_"+IntegerToString(i);
         ResetLastError(); GlobalVariableSet(name,(double)StringToInteger(seqParts[i])); e=GetLastError(); if(e!=0){if(err==0)err=e; ok=false;}
      }
   }
   else ok=false;

   string filename="MoveCatcher_state_"+system+".dat";
   int handle=FileOpen(filename,FILE_COMMON|FILE_WRITE|FILE_TXT);
   if(handle==INVALID_HANDLE){int e=GetLastError(); if(err==0)err=e; ok=false;}
   else
   {
      if(FileWrite(handle,data)<=0){int e=GetLastError(); if(err==0)err=e; ok=false;}
      FileClose(handle);
   }
   return(ok);
}

bool LoadDMCState(const string system,CDecompMC &state)
{
   string prefix="MoveCatcher_"+system+"_";
   if(GlobalVariableCheck(prefix+"seq_size") && GlobalVariableCheck(prefix+"stock") && GlobalVariableCheck(prefix+"streak"))
   {
      int n=(int)MathRound(GlobalVariableGet(prefix+"seq_size"));
      int stock=(int)MathRound(GlobalVariableGet(prefix+"stock"));
      int streak=(int)MathRound(GlobalVariableGet(prefix+"streak"));
      string seqStr=""; bool ok=true;
      for(int i=0;i<n;i++)
      {
         string name=prefix+"seq_"+IntegerToString(i);
         if(!GlobalVariableCheck(name)){ok=false; break;}
         int v=(int)MathRound(GlobalVariableGet(name));
         if(i) seqStr+=","; seqStr+=IntegerToString(v);
      }
      if(ok)
      {
         string data=IntegerToString(stock)+"|"+IntegerToString(streak)+"|"+seqStr;
         if(state.Deserialize(data)) return(true);
      }
   }

   string filename="MoveCatcher_state_"+system+".dat";
   if(FileIsExist(filename,FILE_COMMON))
   {
      int handle=FileOpen(filename,FILE_COMMON|FILE_READ|FILE_TXT);
      if(handle!=INVALID_HANDLE)
      {
         string data=FileReadString(handle);
         FileClose(handle);
         if(state.Deserialize(data)) return(true);
      }
   }

   state.Init();
   return(false);
}

//+------------------------------------------------------------------+
//| Check spread and distance band for a candidate order price       |
//+------------------------------------------------------------------+
bool CanPlaceOrder(double &price,const bool isBuy)
{
   RefreshRates();

   double stopLevel   = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
   double freezeLevel = MarketInfo(Symbol(), MODE_FREEZELEVEL) * Point;

   double ref  = isBuy ? Ask : Bid;
   double dist = MathAbs(price - ref);

   if(dist < freezeLevel)
   {
      PrintFormat("CanPlaceOrder: price %.5f within freeze level %.1f pips, retry next tick",
                  price, PriceToPips(freezeLevel));
      return(false);
   }

   if(dist < stopLevel)
   {
      double oldPrice = price;
      price = isBuy ? ref + stopLevel : ref - stopLevel;
      price = NormalizeDouble(price, Digits);
      PrintFormat("CanPlaceOrder: price adjusted from %.5f to %.5f due to stop level %.1f pips",
                  oldPrice, price, PriceToPips(stopLevel));
   }

   double spread = PriceToPips(Ask - Bid);
   if(spread > MaxSpreadPips)
   {
      PrintFormat("Spread %.1f exceeds MaxSpreadPips %.1f", spread, MaxSpreadPips);
      return(false);
   }

   if(UseDistanceBand)
   {
      dist = PriceToPips(MathAbs(price - ref));
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
double CalcLot(const string system,string &seq,double &lotFactor)
{
   CDecompMC *state = NULL;
   if(system == "A")
      state = &stateA;
   else if(system == "B")
      state = &stateB;
   else
   {
      seq = "";
      lotFactor = 0.0;
      return(0.0);
   }

   lotFactor          = state.NextLot();
   seq                = "(" + state.Seq() + ")";
   double lotCandidate = BaseLot * lotFactor;

   if(lotCandidate > MaxLot)
   {
      state.Init();

      lotFactor    = state.NextLot();
      seq          = "(" + state.Seq() + ")";
      lotCandidate = BaseLot * lotFactor;
      lotCandidate = MathMin(lotCandidate, MaxLot);
      double lotActual = NormalizeLot(lotCandidate);
      if(lotActual > MaxLot)
         lotActual = NormalizeLot(MaxLot);

      LogRecord lr;
      lr.Time       = TimeCurrent();
      lr.Symbol     = Symbol();
      lr.System     = system;
      lr.Reason     = "LOT_RESET";
      lr.Spread     = PriceToPips(Ask - Bid);
      lr.Dist       = 0;
      lr.GridPips   = GridPips;
      lr.s          = s;
      lr.lotFactor  = lotFactor;
      lr.BaseLot    = BaseLot;
      lr.MaxLot     = MaxLot;
      lr.actualLot  = lotActual;
      lr.seqStr     = seq;
      lr.CommentTag = "";
      lr.Magic      = MagicNumber;
      lr.OrderType  = "";
      lr.EntryPrice = 0;
      lr.SL         = 0;
      lr.TP         = 0;
      lr.ErrorCode  = 0;
      WriteLog(lr);

      return(lotActual);
   }

   lotCandidate = MathMin(lotCandidate, MaxLot);
   double lotActual = NormalizeLot(lotCandidate);
   if(lotActual > MaxLot)
      lotActual = NormalizeLot(MaxLot);
   return(lotActual);
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
   if(prev == Missing)
      return(Missing);
   return(None);
}

//+------------------------------------------------------------------+
//| Initialize last close times for both systems                      |
//+------------------------------------------------------------------+
void InitCloseTimes()
{
   lastCloseTimeA = 0;
   lastCloseTimeB = 0;
   for(int i = OrdersHistoryTotal()-1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY))
         continue;
      if(OrderMagicNumber() != MagicNumber || OrderSymbol() != Symbol())
         continue;
      int type = OrderType();
      if(type != OP_BUY && type != OP_SELL)
         continue;
      string sys, seq;
      if(!ParseComment(OrderComment(), sys, seq))
         continue;
      datetime ct = OrderCloseTime();
      if(sys == "A" && ct > lastCloseTimeA)
         lastCloseTimeA = ct;
      else if(sys == "B" && ct > lastCloseTimeB)
         lastCloseTimeB = ct;
   }
}

//+------------------------------------------------------------------+
//| Process newly closed trades for specified system                  |
//+------------------------------------------------------------------+
void ProcessClosedTrades(const string system)
{
   datetime lastTime = (system == "A") ? lastCloseTimeA : lastCloseTimeB;
   int tickets[];
   datetime times[];
   for(int i = OrdersHistoryTotal()-1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY))
         continue;
      if(OrderMagicNumber() != MagicNumber || OrderSymbol() != Symbol())
         continue;
      int type = OrderType();
      if(type != OP_BUY && type != OP_SELL)
         continue;
      string sys, seq;
      if(!ParseComment(OrderComment(), sys, seq))
         continue;
      if(sys != system)
         continue;
      datetime ct = OrderCloseTime();
      if(ct <= lastTime)
         continue;
      int idx = ArraySize(tickets);
      ArrayResize(tickets, idx + 1);
      ArrayResize(times, idx + 1);
      tickets[idx] = OrderTicket();
      times[idx]   = ct;
   }
   for(int i = ArraySize(tickets)-1; i >= 0; i--)
   {
      if(!OrderSelect(tickets[i], SELECT_BY_TICKET, MODE_HISTORY))
         continue;
      double profit = OrderProfit() + OrderSwap() + OrderCommission();
      bool win = (profit >= 0);
      if(system == "A")
      {
         stateA.OnTrade(win);
         if(times[i] > lastCloseTimeA)
            lastCloseTimeA = times[i];
      }
      else
      {
         stateB.OnTrade(win);
         if(times[i] > lastCloseTimeB)
            lastCloseTimeB = times[i];
      }
   }
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
   double stopLevel   = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
   double freezeLevel = MarketInfo(Symbol(), MODE_FREEZELEVEL) * Point;
   double minDist     = MathMax(stopLevel, freezeLevel);
   if(OrderType() == OP_BUY)
   {
      desiredSL = entry - PipsToPrice(GridPips);
      desiredTP = entry + PipsToPrice(GridPips);
      if(Bid - desiredSL < minDist)
         desiredSL = Bid - minDist;
      if(desiredTP - Ask < minDist)
         desiredTP = Ask + minDist;
   }
   else
   {
      desiredSL = entry + PipsToPrice(GridPips);
      desiredTP = entry - PipsToPrice(GridPips);
      if(desiredSL - Ask < minDist)
         desiredSL = Ask + minDist;
      if(Bid - desiredTP < minDist)
         desiredTP = Bid - minDist;
   }
   desiredSL = NormalizeDouble(desiredSL, Digits);
   desiredTP = NormalizeDouble(desiredTP, Digits);
   double tol = Point * 0.5;
   bool needModify = (OrderStopLoss() == 0 || OrderTakeProfit() == 0 ||
                      MathAbs(OrderStopLoss() - desiredSL) > tol ||
                      MathAbs(OrderTakeProfit() - desiredTP) > tol);
   if(needModify)
   {
      if(!OrderModify(ticket, entry, desiredSL, desiredTP, 0, clrNONE))
      {
         int err = GetLastError();
         if(err == 130 || err == 145)
            PrintFormat("EnsureTPSL: TP/SL for ticket %d within stop/freeze level, retry next tick err=%d", ticket, err);
         else
            PrintFormat("EnsureTPSL: failed to set TP/SL for ticket %d err=%d", ticket, err);
      }
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
   double lotFactor;
   double lot = CalcLot(system, seq, lotFactor);
   if(lot <= 0)
      return;
   double price = isBuy ? entry + PipsToPrice(GridPips)
                        : entry - PipsToPrice(GridPips);
   price = NormalizeDouble(price, Digits);
   int type = isBuy ? OP_SELLLIMIT : OP_BUYLIMIT;
   string comment = MakeComment(system, seq);

   RefreshRates();
   double stopLevel   = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
   double freezeLevel = MarketInfo(Symbol(), MODE_FREEZELEVEL) * Point;
   double ref         = (type == OP_BUYLIMIT) ? Ask : Bid;
   double dist        = MathAbs(price - ref);
   if(dist < freezeLevel)
   {
      PrintFormat("EnsureShadowOrder: price %.5f within freeze level %.1f pips, retry next tick", price, PriceToPips(freezeLevel));
      return;
   }
   if(dist < stopLevel)
   {
      PrintFormat("EnsureShadowOrder: price %.5f within stop level %.1f pips, retry next tick", price, PriceToPips(stopLevel));
      return;
   }
   int tk = OrderSend(Symbol(), type, lot, price, 0, 0, 0, comment, MagicNumber, 0, clrNONE);
   LogRecord lr;
   lr.Time       = TimeCurrent();
   lr.Symbol     = Symbol();
   lr.System     = system;
   // REFILL: 影指値（TP反転用の指値）を設置
   lr.Reason     = "REFILL";
   lr.Spread     = PriceToPips(Ask - Bid);
   lr.Dist       = GridPips;
   lr.GridPips   = GridPips;
   lr.s          = s;
   lr.lotFactor  = lotFactor;
   lr.BaseLot    = BaseLot;
   lr.MaxLot     = MaxLot;
   lr.actualLot  = lot;
   lr.seqStr     = seq;
   lr.CommentTag = comment;
   lr.Magic      = MagicNumber;
   lr.OrderType  = OrderTypeToStr(type);
   lr.EntryPrice = price;
   lr.SL         = 0;
   lr.TP         = 0;
   lr.ErrorCode  = (tk < 0) ? GetLastError() : 0;
   WriteLog(lr);
   if(tk < 0)
      PrintFormat("EnsureShadowOrder: failed to place shadow order for %s err=%d", system, lr.ErrorCode);
}

//+------------------------------------------------------------------+
//| Delete all pending orders for specified system                    |
//+------------------------------------------------------------------+
void DeletePendings(const string system,const string reason)
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
      int err = 0;
      bool ok = OrderDelete(tk);
      if(!ok)
         err = GetLastError();
      LogRecord lr;
      lr.Time       = TimeCurrent();
      lr.Symbol     = Symbol();
      lr.System     = system;
      lr.Reason     = reason;
      lr.Spread     = PriceToPips(Ask - Bid);
      lr.Dist       = 0;
      lr.GridPips   = GridPips;
      lr.s          = s;
      lr.lotFactor  = 0;
      lr.BaseLot    = BaseLot;
      lr.MaxLot     = MaxLot;
      lr.actualLot  = OrderLots();
      lr.seqStr     = seq;
      lr.CommentTag = OrderComment();
      lr.Magic      = MagicNumber;
      lr.OrderType  = OrderTypeToStr(type);
      lr.EntryPrice = OrderOpenPrice();
      lr.SL         = OrderStopLoss();
      lr.TP         = OrderTakeProfit();
      lr.ErrorCode  = err;
      WriteLog(lr);
      if(!ok)
         PrintFormat("DeletePendings: failed to delete %d err=%d", tk, err);
   }
}

//+------------------------------------------------------------------+
//| Re-enter position after SL according to UseProtectedLimit         |
//+------------------------------------------------------------------+
void RecoverAfterSL(const string system)
{
   RefreshRates();
   ProcessClosedTrades(system);
   DeletePendings(system, "SL");

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
   double lotFactor;
   double lot = CalcLot(system, seq, lotFactor);
   if(lot <= 0)
      return;

   bool   isBuy    = (lastType == OP_BUY);
   int    slippage = UseProtectedLimit ? (int)(SlippagePips * Pip() / Point) : 0;
   double price    = isBuy ? Ask : Bid;
   double sl       = isBuy ? price - PipsToPrice(GridPips) : price + PipsToPrice(GridPips);
   double tp       = isBuy ? price + PipsToPrice(GridPips) : price - PipsToPrice(GridPips);
   double stopLevel   = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
   double freezeLevel = MarketInfo(Symbol(), MODE_FREEZELEVEL) * Point;
   double minLevel    = MathMax(stopLevel, freezeLevel);

   double distSL = MathAbs(price - sl);
   if(distSL < minLevel)
   {
      double oldSL = sl;
      sl = isBuy ? price - minLevel : price + minLevel;
      sl = NormalizeDouble(sl, Digits);
      PrintFormat("RecoverAfterSL: SL adjusted from %.5f to %.5f due to min distance %.1f pips",
                  oldSL, sl, PriceToPips(minLevel));
   }

   double distTP = MathAbs(tp - price);
   if(distTP < minLevel)
   {
      double oldTP = tp;
      tp = isBuy ? price + minLevel : price - minLevel;
      tp = NormalizeDouble(tp, Digits);
      PrintFormat("RecoverAfterSL: TP adjusted from %.5f to %.5f due to min distance %.1f pips",
                  oldTP, tp, PriceToPips(minLevel));
   }
   string comment  = MakeComment(system, seq);
   int type        = isBuy ? OP_BUY : OP_SELL;
   int ticket      = OrderSend(Symbol(), type, lot, price,
                               slippage, sl, tp, comment, MagicNumber, 0, clrNONE);
   LogRecord lr;
   lr.Time       = TimeCurrent();
   lr.Symbol     = Symbol();
   lr.System     = system;
   lr.Reason     = "SL";
   lr.Spread     = PriceToPips(Ask - Bid);
   lr.Dist       = 0;
   lr.GridPips   = GridPips;
   lr.s          = s;
   lr.lotFactor  = lotFactor;
   lr.BaseLot    = BaseLot;
   lr.MaxLot     = MaxLot;
   lr.actualLot  = lot;
   lr.seqStr     = seq;
   lr.CommentTag = comment;
   lr.Magic      = MagicNumber;
   lr.OrderType  = OrderTypeToStr(type);
   lr.ErrorCode  = (ticket < 0) ? GetLastError() : 0;
   if(ticket < 0)
   {
      WriteLog(lr);
      PrintFormat("RecoverAfterSL: failed to reopen %s err=%d", system, lr.ErrorCode);
      return;
   }

   if(!OrderSelect(ticket, SELECT_BY_TICKET))
   {
      lr.ErrorCode = GetLastError();
      WriteLog(lr);
      PrintFormat("RecoverAfterSL: failed to select reopened order for %s err=%d", system, lr.ErrorCode);
      return;
   }
   double entry = OrderOpenPrice();
   double desiredSL = isBuy ? entry - PipsToPrice(GridPips) : entry + PipsToPrice(GridPips);
   double desiredTP = isBuy ? entry + PipsToPrice(GridPips) : entry - PipsToPrice(GridPips);
   double stopLevel   = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
   double freezeLevel = MarketInfo(Symbol(), MODE_FREEZELEVEL) * Point;
   double minLevel    = MathMax(stopLevel, freezeLevel);
   if(isBuy)
   {
      if(Bid - desiredSL < minLevel)
         desiredSL = Bid - minLevel;
      if(desiredTP - Ask < minLevel)
         desiredTP = Ask + minLevel;
   }
   else
   {
      if(desiredSL - Ask < minLevel)
         desiredSL = Ask + minLevel;
      if(Bid - desiredTP < minLevel)
         desiredTP = Bid - minLevel;
   }
   desiredSL = NormalizeDouble(desiredSL, Digits);
   desiredTP = NormalizeDouble(desiredTP, Digits);
   if(!OrderModify(ticket, entry, desiredSL, desiredTP, 0, clrNONE))
   {
      int err = GetLastError();
      PrintFormat("RecoverAfterSL: failed to adjust TP/SL for %s ticket %d err=%d", system, ticket, err);
   }
   lr.EntryPrice = entry;
   lr.SL         = desiredSL;
   lr.TP         = desiredTP;
   WriteLog(lr);

   EnsureShadowOrder(ticket, system);

   if(system == "A")
      state_A = Alive;
   else if(system == "B")
      state_B = Alive;
}

//+------------------------------------------------------------------+
//| Close all positions and pending orders managed by this EA        |
//+------------------------------------------------------------------+
void CloseAllOrders(const string reason)
{
   bool updateDMC = (reason != "RESET_ALIVE" && reason != "RESET_SNAP");
   RefreshRates();
   for(int i = OrdersTotal()-1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderMagicNumber() != MagicNumber || OrderSymbol() != Symbol())
         continue;
      int type   = OrderType();
      int ticket = OrderTicket();
      if(type == OP_BUY || type == OP_SELL)
      {
         double price = (type == OP_BUY) ? Bid : Ask;
         int err = 0;
         bool ok = OrderClose(ticket, OrderLots(), price, 0, clrNONE);
         if(!ok)
            err = GetLastError();
         string sysTmp, seqTmp;
         ParseComment(OrderComment(), sysTmp, seqTmp);
         LogRecord lr;
         lr.Time       = TimeCurrent();
         lr.Symbol     = Symbol();
         lr.System     = "";
         lr.Reason     = reason;
         lr.Spread     = PriceToPips(Ask - Bid);
         lr.Dist       = 0;
         lr.GridPips   = GridPips;
         lr.s          = s;
         lr.lotFactor  = 0;
         lr.BaseLot    = BaseLot;
         lr.MaxLot     = MaxLot;
         lr.actualLot  = OrderLots();
         lr.seqStr     = seqTmp;
         lr.CommentTag = OrderComment();
         lr.Magic      = MagicNumber;
         lr.OrderType  = OrderTypeToStr(type);
         lr.EntryPrice = OrderOpenPrice();
         lr.SL         = OrderStopLoss();
         lr.TP         = OrderTakeProfit();
         lr.ErrorCode  = err;
         lr.System     = sysTmp;
         WriteLog(lr);
         if(!ok)
            PrintFormat("CloseAllOrders: failed to close %d err=%d", ticket, err);
         else if(updateDMC)
            ProcessClosedTrades(sysTmp);
      }
      else if(type == OP_BUYLIMIT || type == OP_SELLLIMIT ||
              type == OP_BUYSTOP  || type == OP_SELLSTOP)
      {
         int err = 0;
         bool ok = OrderDelete(ticket);
         if(!ok)
            err = GetLastError();
         LogRecord lr;
         lr.Time       = TimeCurrent();
         lr.Symbol     = Symbol();
         string sysTmp2, seqTmp2;
         ParseComment(OrderComment(), sysTmp2, seqTmp2);
         lr.System     = sysTmp2;
         lr.Reason     = reason;
         lr.Spread     = PriceToPips(Ask - Bid);
         lr.Dist       = 0;
         lr.GridPips   = GridPips;
         lr.s          = s;
         lr.lotFactor  = 0;
         lr.BaseLot    = BaseLot;
         lr.MaxLot     = MaxLot;
         lr.actualLot  = OrderLots();
         lr.seqStr     = seqTmp2;
         lr.CommentTag = OrderComment();
         lr.Magic      = MagicNumber;
         lr.OrderType  = OrderTypeToStr(type);
         lr.EntryPrice = OrderOpenPrice();
         lr.SL         = OrderStopLoss();
         lr.TP         = OrderTakeProfit();
         lr.ErrorCode  = err;
         WriteLog(lr);
         if(!ok)
            PrintFormat("CloseAllOrders: failed to delete %d err=%d", ticket, err);
      }
   }
}

//+------------------------------------------------------------------+
//| Ensure only one position per system                              |
//+------------------------------------------------------------------+
void CorrectDuplicatePositions()
{
   RefreshRates();

   int ticketsA[]; datetime timesA[];
   int ticketsB[]; datetime timesB[];

   for(int i = OrdersTotal()-1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderMagicNumber() != MagicNumber || OrderSymbol() != Symbol())
         continue;
      int type = OrderType();
      if(type != OP_BUY && type != OP_SELL)
         continue;
      string sys, seq;
      if(!ParseComment(OrderComment(), sys, seq))
         continue;
      if(sys == "A")
      {
         int idx = ArraySize(ticketsA);
         ArrayResize(ticketsA, idx + 1);
         ArrayResize(timesA, idx + 1);
         ticketsA[idx] = OrderTicket();
         timesA[idx]   = OrderOpenTime();
      }
      else if(sys == "B")
      {
         int idx = ArraySize(ticketsB);
         ArrayResize(ticketsB, idx + 1);
         ArrayResize(timesB, idx + 1);
         ticketsB[idx] = OrderTicket();
         timesB[idx]   = OrderOpenTime();
      }
   }

   int countA = ArraySize(ticketsA);
   if(countA > 1)
   {
      int keep = 0;
      for(int i = 1; i < countA; i++)
         if(timesA[i] < timesA[keep])
            keep = i;
      for(int i = 0; i < countA; i++)
      {
         if(i == keep)
            continue;
         int tk = ticketsA[i];
         if(!OrderSelect(tk, SELECT_BY_TICKET))
            continue;
         double price = (OrderType() == OP_BUY) ? Bid : Ask;
         int err = 0;
         bool ok = OrderClose(tk, OrderLots(), price, 0, clrNONE);
         if(!ok)
            err = GetLastError();
         LogRecord lr;
         lr.Time       = TimeCurrent();
         lr.Symbol     = Symbol();
         lr.System     = "A";
         lr.Reason     = "RESET_ALIVE";
         lr.Spread     = PriceToPips(Ask - Bid);
         lr.Dist       = 0;
         lr.GridPips   = GridPips;
         lr.s          = s;
         lr.lotFactor  = 0;
         lr.BaseLot    = BaseLot;
         lr.MaxLot     = MaxLot;
         lr.actualLot  = OrderLots();
         string sysTmp, seqTmp;
         ParseComment(OrderComment(), sysTmp, seqTmp);
         lr.seqStr     = seqTmp;
         lr.CommentTag = OrderComment();
         lr.Magic      = MagicNumber;
         lr.OrderType  = OrderTypeToStr(OrderType());
         lr.EntryPrice = OrderOpenPrice();
         lr.SL         = OrderStopLoss();
         lr.TP         = OrderTakeProfit();
         lr.ErrorCode  = err;
         WriteLog(lr);
         if(!ok)
            PrintFormat("CorrectDuplicatePositions: failed to close %d err=%d", tk, err);
      }
      ProcessClosedTrades("A");
      DeletePendings("A", "RESET_ALIVE");
   }

   int countB = ArraySize(ticketsB);
   if(countB > 1)
   {
      int keepB = 0;
      for(int i = 1; i < countB; i++)
         if(timesB[i] < timesB[keepB])
            keepB = i;
      for(int i = 0; i < countB; i++)
      {
         if(i == keepB)
            continue;
         int tk = ticketsB[i];
         if(!OrderSelect(tk, SELECT_BY_TICKET))
            continue;
         double price = (OrderType() == OP_BUY) ? Bid : Ask;
         int err = 0;
         bool ok = OrderClose(tk, OrderLots(), price, 0, clrNONE);
         if(!ok)
            err = GetLastError();
         LogRecord lr;
         lr.Time       = TimeCurrent();
         lr.Symbol     = Symbol();
         lr.System     = "B";
         lr.Reason     = "RESET_ALIVE";
         lr.Spread     = PriceToPips(Ask - Bid);
         lr.Dist       = 0;
         lr.GridPips   = GridPips;
         lr.s          = s;
         lr.lotFactor  = 0;
         lr.BaseLot    = BaseLot;
         lr.MaxLot     = MaxLot;
         lr.actualLot  = OrderLots();
         string sysTmp2, seqTmp2;
         ParseComment(OrderComment(), sysTmp2, seqTmp2);
         lr.seqStr     = seqTmp2;
         lr.CommentTag = OrderComment();
         lr.Magic      = MagicNumber;
         lr.OrderType  = OrderTypeToStr(OrderType());
         lr.EntryPrice = OrderOpenPrice();
         lr.SL         = OrderStopLoss();
         lr.TP         = OrderTakeProfit();
         lr.ErrorCode  = err;
         WriteLog(lr);
         if(!ok)
            PrintFormat("CorrectDuplicatePositions: failed to close %d err=%d", tk, err);
      }
      ProcessClosedTrades("B");
      DeletePendings("B", "RESET_ALIVE");
   }
}

//+------------------------------------------------------------------+
//| Place refill pending orders at ±s from reference price           |
//+------------------------------------------------------------------+
void PlaceRefillOrders(const string system,const double refPrice)
{
   RefreshRates();

   string seq;
   double lotFactor;
   double lot = CalcLot(system, seq, lotFactor);
   if(lot <= 0)
      return;

   string comment  = MakeComment(system, seq);
   double priceSell = refPrice + PipsToPrice(s);
   double priceBuy  = refPrice - PipsToPrice(s);

   double stopLevel   = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
   double freezeLevel = MarketInfo(Symbol(), MODE_FREEZELEVEL) * Point;

   double distSell = MathAbs(Bid - priceSell);
   if(distSell < freezeLevel)
      PrintFormat("PlaceRefillOrders: SellLimit %.5f within freeze level %.1f pips, retry next tick",
                  priceSell, PriceToPips(freezeLevel));
   else
   {
      if(distSell < stopLevel)
      {
         double old = priceSell;
         priceSell = NormalizeDouble(Bid + stopLevel, Digits);
         PrintFormat("PlaceRefillOrders: SellLimit adjusted from %.5f to %.5f due to stop level %.1f pips",
                     old, priceSell, PriceToPips(stopLevel));
      }
      if(CanPlaceOrder(priceSell, false))
      {
         int ticketSell = OrderSend(Symbol(), OP_SELLLIMIT, lot, priceSell,
                                    0, 0, 0, comment, MagicNumber, 0, clrNONE);
      LogRecord lr;
      lr.Time       = TimeCurrent();
      lr.Symbol     = Symbol();
      lr.System     = system;
      lr.Reason     = "REFILL";
      lr.Spread     = PriceToPips(Ask - Bid);
      lr.Dist       = PriceToPips(MathAbs(priceSell - refPrice));
      lr.GridPips   = GridPips;
      lr.s          = s;
      lr.lotFactor  = lotFactor;
      lr.BaseLot    = BaseLot;
      lr.MaxLot     = MaxLot;
      lr.actualLot  = lot;
      lr.seqStr     = seq;
      lr.CommentTag = comment;
      lr.Magic      = MagicNumber;
      lr.OrderType  = OrderTypeToStr(OP_SELLLIMIT);
      lr.EntryPrice = priceSell;
      lr.SL         = 0;
      lr.TP         = 0;
      lr.ErrorCode  = (ticketSell < 0) ? GetLastError() : 0;
      WriteLog(lr);
      if(ticketSell < 0)
         PrintFormat("PlaceRefillOrders: failed to place SellLimit for %s err=%d", system, lr.ErrorCode);
      }
   }

   double distBuy = MathAbs(Ask - priceBuy);
   if(distBuy < freezeLevel)
      PrintFormat("PlaceRefillOrders: BuyLimit %.5f within freeze level %.1f pips, retry next tick",
                  priceBuy, PriceToPips(freezeLevel));
   else
   {
      if(distBuy < stopLevel)
      {
         double oldB = priceBuy;
         priceBuy = NormalizeDouble(Ask - stopLevel, Digits);
         PrintFormat("PlaceRefillOrders: BuyLimit adjusted from %.5f to %.5f due to stop level %.1f pips",
                     oldB, priceBuy, PriceToPips(stopLevel));
      }
      if(CanPlaceOrder(priceBuy, true))
      {
         int ticketBuy = OrderSend(Symbol(), OP_BUYLIMIT, lot, priceBuy,
                                   0, 0, 0, comment, MagicNumber, 0, clrNONE);
      LogRecord lr;
      lr.Time       = TimeCurrent();
      lr.Symbol     = Symbol();
      lr.System     = system;
      lr.Reason     = "REFILL";
      lr.Spread     = PriceToPips(Ask - Bid);
      lr.Dist       = PriceToPips(MathAbs(priceBuy - refPrice));
      lr.GridPips   = GridPips;
      lr.s          = s;
      lr.lotFactor  = lotFactor;
      lr.BaseLot    = BaseLot;
      lr.MaxLot     = MaxLot;
      lr.actualLot  = lot;
      lr.seqStr     = seq;
      lr.CommentTag = comment;
      lr.Magic      = MagicNumber;
      lr.OrderType  = OrderTypeToStr(OP_BUYLIMIT);
      lr.EntryPrice = priceBuy;
      lr.SL         = 0;
      lr.TP         = 0;
      lr.ErrorCode  = (ticketBuy < 0) ? GetLastError() : 0;
      WriteLog(lr);
      if(ticketBuy < 0)
         PrintFormat("PlaceRefillOrders: failed to place BuyLimit for %s err=%d", system, lr.ErrorCode);
      }
   }
}

//+------------------------------------------------------------------+
//| Place initial market order for system A and OCO limits for B     |
//+------------------------------------------------------------------+
void InitStrategy()
{
   RefreshRates();

   //---- system A market order
   string seqA; double lotFactorA; double lotA = CalcLot("A", seqA, lotFactorA);
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

   double stopLevel   = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
   double freezeLevel = MarketInfo(Symbol(), MODE_FREEZELEVEL) * Point;
   double minLevel    = MathMax(stopLevel, freezeLevel);

   double distSL = MathAbs(price - entrySL);
   if(distSL < minLevel)
   {
      double oldSL = entrySL;
      entrySL = isBuy ? price - minLevel : price + minLevel;
      entrySL = NormalizeDouble(entrySL, Digits);
      PrintFormat("InitStrategy: SL adjusted from %.5f to %.5f due to min distance %.1f pips",
                  oldSL, entrySL, PriceToPips(minLevel));
   }

   double distTP = MathAbs(entryTP - price);
   if(distTP < minLevel)
   {
      double oldTP = entryTP;
      entryTP = isBuy ? price + minLevel : price - minLevel;
      entryTP = NormalizeDouble(entryTP, Digits);
      PrintFormat("InitStrategy: TP adjusted from %.5f to %.5f due to min distance %.1f pips",
                  oldTP, entryTP, PriceToPips(minLevel));
   }

   string commentA = MakeComment("A", seqA);
   int typeA   = isBuy ? OP_BUY : OP_SELL;
   int ticketA = OrderSend(Symbol(), typeA, lotA, price,
                           slippage, entrySL, entryTP, commentA, MagicNumber, 0, clrNONE);
   LogRecord lrA;
   lrA.Time       = TimeCurrent();
   lrA.Symbol     = Symbol();
   lrA.System     = "A";
   lrA.Reason     = "INIT";
   lrA.Spread     = PriceToPips(Ask - Bid);
   lrA.Dist       = 0;
   lrA.GridPips   = GridPips;
   lrA.s          = s;
   lrA.lotFactor  = lotFactorA;
   lrA.BaseLot    = BaseLot;
   lrA.MaxLot     = MaxLot;
   lrA.actualLot  = lotA;
   lrA.seqStr     = seqA;
   lrA.CommentTag = commentA;
   lrA.Magic      = MagicNumber;
   lrA.OrderType  = OrderTypeToStr(typeA);
   lrA.EntryPrice = price;
   lrA.SL         = entrySL;
   lrA.TP         = entryTP;
   lrA.ErrorCode  = (ticketA < 0) ? GetLastError() : 0;
   WriteLog(lrA);
   if(ticketA < 0)
   {
      PrintFormat("InitStrategy: failed to place system A order, err=%d", lrA.ErrorCode);
      return;
   }

   if(!OrderSelect(ticketA, SELECT_BY_TICKET))
      return;
   double entryPrice = OrderOpenPrice();

   EnsureShadowOrder(ticketA, "A");

   //---- system B OCO pending orders
   string seqB; double lotFactorB; double lotB = CalcLot("B", seqB, lotFactorB);
   if(lotB <= 0) return;
   string commentB = MakeComment("B", seqB);

   double priceSell = entryPrice + PipsToPrice(s);
   double priceBuy  = entryPrice - PipsToPrice(s);
   stopLevel   = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
   freezeLevel = MarketInfo(Symbol(), MODE_FREEZELEVEL) * Point;

   double distSell = MathAbs(Bid - priceSell);
   if(distSell < freezeLevel)
      PrintFormat("InitStrategy: SellLimit %.5f within freeze level %.1f pips, retry next tick",
                  priceSell, PriceToPips(freezeLevel));
   else
   {
      if(distSell < stopLevel)
      {
         double oldS = priceSell;
         priceSell = NormalizeDouble(Bid + stopLevel, Digits);
         PrintFormat("InitStrategy: SellLimit adjusted from %.5f to %.5f due to stop level %.1f pips",
                     oldS, priceSell, PriceToPips(stopLevel));
      }
      if(CanPlaceOrder(priceSell, false))
      {
         int ticketSell = OrderSend(Symbol(), OP_SELLLIMIT, lotB, priceSell,
                                    0, 0, 0, commentB, MagicNumber, 0, clrNONE);
      LogRecord lrS;
      lrS.Time       = TimeCurrent();
      lrS.Symbol     = Symbol();
      lrS.System     = "B";
      lrS.Reason     = "INIT";
      lrS.Spread     = PriceToPips(Ask - Bid);
      lrS.Dist       = PriceToPips(MathAbs(priceSell - entryPrice));
      lrS.GridPips   = GridPips;
      lrS.s          = s;
      lrS.lotFactor  = lotFactorB;
      lrS.BaseLot    = BaseLot;
      lrS.MaxLot     = MaxLot;
      lrS.actualLot  = lotB;
      lrS.seqStr     = seqB;
      lrS.CommentTag = commentB;
      lrS.Magic      = MagicNumber;
      lrS.OrderType  = OrderTypeToStr(OP_SELLLIMIT);
      lrS.EntryPrice = priceSell;
      lrS.SL         = 0;
      lrS.TP         = 0;
      lrS.ErrorCode  = (ticketSell < 0) ? GetLastError() : 0;
      WriteLog(lrS);
      if(ticketSell < 0)
         PrintFormat("InitStrategy: failed to place SellLimit, err=%d", lrS.ErrorCode);
      }
   }

   double distBuy = MathAbs(Ask - priceBuy);
   if(distBuy < freezeLevel)
      PrintFormat("InitStrategy: BuyLimit %.5f within freeze level %.1f pips, retry next tick",
                  priceBuy, PriceToPips(freezeLevel));
   else
   {
      if(distBuy < stopLevel)
      {
         double oldB = priceBuy;
         priceBuy = NormalizeDouble(Ask - stopLevel, Digits);
         PrintFormat("InitStrategy: BuyLimit adjusted from %.5f to %.5f due to stop level %.1f pips",
                     oldB, priceBuy, PriceToPips(stopLevel));
      }
      if(CanPlaceOrder(priceBuy, true))
      {
         int ticketBuy = OrderSend(Symbol(), OP_BUYLIMIT, lotB, priceBuy,
                                   0, 0, 0, commentB, MagicNumber, 0, clrNONE);
      LogRecord lrB;
      lrB.Time       = TimeCurrent();
      lrB.Symbol     = Symbol();
      lrB.System     = "B";
      lrB.Reason     = "INIT";
      lrB.Spread     = PriceToPips(Ask - Bid);
      lrB.Dist       = PriceToPips(MathAbs(priceBuy - entryPrice));
      lrB.GridPips   = GridPips;
      lrB.s          = s;
      lrB.lotFactor  = lotFactorB;
      lrB.BaseLot    = BaseLot;
      lrB.MaxLot     = MaxLot;
      lrB.actualLot  = lotB;
      lrB.seqStr     = seqB;
      lrB.CommentTag = commentB;
      lrB.Magic      = MagicNumber;
      lrB.OrderType  = OrderTypeToStr(OP_BUYLIMIT);
      lrB.EntryPrice = priceBuy;
      lrB.SL         = 0;
      lrB.TP         = 0;
      lrB.ErrorCode  = (ticketBuy < 0) ? GetLastError() : 0;
      WriteLog(lrB);
      if(ticketBuy < 0)
         PrintFormat("InitStrategy: failed to place BuyLimit, err=%d", lrB.ErrorCode);
      }
   }
}

//+------------------------------------------------------------------+
//| Detect filled OCO for specified system                            |
//+------------------------------------------------------------------+
void HandleOCODetectionFor(const string system)
{
   ProcessClosedTrades(system);
   int posTicket = -1;
   if(system == "A")
   {
      if(retryTicketA != -1)
      {
         if(OrderSelect(retryTicketA, SELECT_BY_TICKET))
            posTicket = retryTicketA;
         else
            retryTicketA = -1;
      }
   }
   else
   {
      if(retryTicketB != -1)
      {
         if(OrderSelect(retryTicketB, SELECT_BY_TICKET))
            posTicket = retryTicketB;
         else
            retryTicketB = -1;
      }
   }
   if(posTicket == -1)
   {
      for(int i = OrdersTotal()-1; i >= 0; i--)
      {
         if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
            continue;
         if(OrderMagicNumber() != MagicNumber || OrderSymbol() != Symbol())
            continue;
         string sys, seq;
         if(!ParseComment(OrderComment(), sys, seq))
            continue;
         if(sys == system && (OrderType() == OP_BUY || OrderType() == OP_SELL))
         {
            posTicket = OrderTicket();
            break;
         }
      }
   }
   if(posTicket == -1)
   {
      if(system == "A")
         retryTicketA = -1;
      else
         retryTicketB = -1;
      return;
   }

   if(!OrderSelect(posTicket, SELECT_BY_TICKET))
   {
      if(system == "A")
         retryTicketA = -1;
      else
         retryTicketB = -1;
      return;
   }

   if(OrderStopLoss() != 0 && OrderTakeProfit() != 0)
   {
      if(system == "A")
         retryTicketA = -1;
      else
         retryTicketB = -1;
      return; // already processed
   }

   // remove remaining pending orders for this system
   for(int i = OrdersTotal()-1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderMagicNumber() != MagicNumber || OrderSymbol() != Symbol())
         continue;
      string sys, seq;
      if(!ParseComment(OrderComment(), sys, seq))
         continue;
      if(sys == system && (OrderType() == OP_BUYLIMIT || OrderType() == OP_SELLLIMIT ||
                           OrderType() == OP_BUYSTOP  || OrderType() == OP_SELLSTOP))
      {
         int delTicket = OrderTicket();
         int err = 0;
         bool ok = OrderDelete(delTicket);
         if(!ok)
            err = GetLastError();
         LogRecord lr;
         lr.Time       = TimeCurrent();
         lr.Symbol     = Symbol();
         lr.System     = system;
         lr.Reason     = "REFILL";
         lr.Spread     = PriceToPips(Ask - Bid);
         lr.Dist       = 0;
         lr.GridPips   = GridPips;
         lr.s          = s;
         lr.lotFactor  = 0;
         lr.BaseLot    = BaseLot;
         lr.MaxLot     = MaxLot;
         lr.actualLot  = OrderLots();
         lr.seqStr     = seq;
         lr.CommentTag = OrderComment();
         lr.Magic      = MagicNumber;
         lr.OrderType  = OrderTypeToStr(OrderType());
         lr.EntryPrice = OrderOpenPrice();
         lr.SL         = OrderStopLoss();
         lr.TP         = OrderTakeProfit();
         lr.ErrorCode  = err;
         WriteLog(lr);
         if(!ok)
            PrintFormat("Failed to delete pending order %d err=%d", delTicket, err);
      }
   }

   double entry = OrderOpenPrice();
   double sl, tp;
   double stopLevel   = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
   double freezeLevel = MarketInfo(Symbol(), MODE_FREEZELEVEL) * Point;
   double minDist     = MathMax(stopLevel, freezeLevel);
   if(OrderType() == OP_BUY)
   {
      sl = entry - PipsToPrice(GridPips);
      tp = entry + PipsToPrice(GridPips);
      if(Bid - sl < minDist)
         sl = Bid - minDist;
      if(tp - Ask < minDist)
         tp = Ask + minDist;
   }
   else
   {
      sl = entry + PipsToPrice(GridPips);
      tp = entry - PipsToPrice(GridPips);
      if(sl - Ask < minDist)
         sl = Ask + minDist;
      if(Bid - tp < minDist)
         tp = Bid - minDist;
   }
   sl = NormalizeDouble(sl, Digits);
   tp = NormalizeDouble(tp, Digits);

   int err = 0;
   if(!OrderModify(posTicket, entry, sl, tp, 0, clrNONE))
   {
      err = GetLastError();
      PrintFormat("Failed to set TP/SL for ticket %d err=%d", posTicket, err);

      string sys2, seq2;
      ParseComment(OrderComment(), sys2, seq2);
      LogRecord lrFail;
      lrFail.Time       = TimeCurrent();
      lrFail.Symbol     = Symbol();
      lrFail.System     = system;
      lrFail.Reason     = "REFILL";
      lrFail.Spread     = PriceToPips(Ask - Bid);
      lrFail.Dist       = 0;
      lrFail.GridPips   = GridPips;
      lrFail.s          = s;
      lrFail.lotFactor  = 0;
      lrFail.BaseLot    = BaseLot;
      lrFail.MaxLot     = MaxLot;
      lrFail.actualLot  = OrderLots();
      lrFail.seqStr     = seq2;
      lrFail.CommentTag = OrderComment();
      lrFail.Magic      = MagicNumber;
      lrFail.OrderType  = OrderTypeToStr(OrderType());
      lrFail.EntryPrice = entry;
      lrFail.SL         = sl;
      lrFail.TP         = tp;
      lrFail.ErrorCode  = err;
      WriteLog(lrFail);

      if(system == "A")
         retryTicketA = posTicket;
      else
         retryTicketB = posTicket;
      return;
   }

   if(system == "A")
      retryTicketA = -1;
   else
      retryTicketB = -1;
   EnsureShadowOrder(posTicket, system);

   string sys2, seq2;
   ParseComment(OrderComment(), sys2, seq2);
   LogRecord lr;
   lr.Time       = TimeCurrent();
   lr.Symbol     = Symbol();
   lr.System     = system;
   lr.Reason     = "REFILL";
   lr.Spread     = PriceToPips(Ask - Bid);
   lr.Dist       = 0;
   lr.GridPips   = GridPips;
   lr.s          = s;
   lr.lotFactor  = 0;
   lr.BaseLot    = BaseLot;
   lr.MaxLot     = MaxLot;
   lr.actualLot  = OrderLots();
   lr.seqStr     = seq2;
   lr.CommentTag = OrderComment();
   lr.Magic      = MagicNumber;
   lr.OrderType  = OrderTypeToStr(OrderType());
   lr.EntryPrice = entry;
   lr.SL         = sl;
   lr.TP         = tp;
   lr.ErrorCode  = 0;
   WriteLog(lr);
}

//+------------------------------------------------------------------+
//| Detect filled OCOs and process for both systems                   |
//+------------------------------------------------------------------+
void HandleOCODetection()
{
   HandleOCODetectionFor("A");
   HandleOCODetectionFor("B");
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

   LoadDMCState("A", stateA);
   LoadDMCState("B", stateB);

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
   InitCloseTimes();
   InitStrategy();

   return(INIT_SUCCEEDED);
}

void OnTick()
{
   HandleOCODetection();
   CorrectDuplicatePositions();

   SystemState prevA = state_A;
   SystemState prevB = state_B;

   bool hasA = false;
   bool hasB = false;
   bool pendA = false;
   bool pendB = false;
   int  ticketA = -1;
   int  ticketB = -1;
   double priceA = 0.0;
   double priceB = 0.0;

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
            {
               hasA = true;
               ticketA = OrderTicket();
               priceA  = OrderOpenPrice();
            }
            else if(system == "B")
            {
               hasB = true;
               ticketB = OrderTicket();
               priceB  = OrderOpenPrice();
            }

         EnsureTPSL(OrderTicket());
         EnsureShadowOrder(OrderTicket(), system);
      }
      else if(type == OP_BUYLIMIT || type == OP_SELLLIMIT ||
              type == OP_BUYSTOP  || type == OP_SELLSTOP)
      {
         if(system == "A")
            pendA = true;
         else if(system == "B")
            pendB = true;
      }
   }

   int posCount = (hasA ? 1 : 0) + (hasB ? 1 : 0);

   if(UseTickSnap && posCount == 2)
   {
      double dist = PriceToPips(MathAbs(priceA - priceB));
      double lower = s - EpsilonPips;
      double upper = s + EpsilonPips;
      if(dist < lower || dist > upper)
      {
         int currentBar = Bars;
         if(lastSnapBar == -1 || currentBar - lastSnapBar >= SnapCooldownBars)
         {
            LogRecord lr;
            lr.Time       = TimeCurrent();
            lr.Symbol     = Symbol();
            lr.System     = "";
            lr.Reason     = "RESET_SNAP";
            lr.Spread     = PriceToPips(Ask - Bid);
            lr.Dist       = dist;
            lr.GridPips   = GridPips;
            lr.s          = s;
            lr.lotFactor  = 0;
            lr.BaseLot    = BaseLot;
            lr.MaxLot     = MaxLot;
            lr.actualLot  = 0;
            lr.seqStr     = "";
            lr.CommentTag = "";
            lr.Magic      = MagicNumber;
            lr.OrderType  = "";
            lr.EntryPrice = 0;
            lr.SL         = 0;
            lr.TP         = 0;
            lr.ErrorCode  = 0;
            WriteLog(lr);
            CloseAllOrders("RESET_SNAP");
            state_A = None;
            state_B = None;
            InitStrategy();
            lastSnapBar = currentBar;
            return;
         }
      }
   }

   SystemState nextA = UpdateState(prevA, hasA);
   SystemState nextB = UpdateState(prevB, hasB);

   if(posCount == 0)
   {
      bool aMissingBClosed = (prevA == Missing && (prevB == Alive || prevB == MissingRecovered) && nextA == Missing && nextB == Missing);
      bool bMissingAClosed = (prevB == Missing && (prevA == Alive || prevA == MissingRecovered) && nextB == Missing && nextA == Missing);
      if(aMissingBClosed || bMissingAClosed)
      {
         LogRecord lr;
         lr.Time       = TimeCurrent();
         lr.Symbol     = Symbol();
         lr.System     = "";
         lr.Reason     = "RESET_ALIVE";
         lr.Spread     = PriceToPips(Ask - Bid);
         lr.Dist       = 0;
         lr.GridPips   = GridPips;
         lr.s          = s;
         lr.lotFactor  = 0;
         lr.BaseLot    = BaseLot;
         lr.MaxLot     = MaxLot;
         lr.actualLot  = 0;
         lr.seqStr     = "";
         lr.CommentTag = "";
         lr.Magic      = MagicNumber;
         lr.OrderType  = "";
         lr.EntryPrice = 0;
         lr.SL         = 0;
         lr.TP         = 0;
         lr.ErrorCode  = 0;
         WriteLog(lr);
         CloseAllOrders("RESET_ALIVE");
         state_A = None;
         state_B = None;
         InitStrategy();
         return;
      }
   }

   if(posCount == 1)
   {
      if(hasA && !hasB && !pendB && ticketA != -1)
      {
         if(OrderSelect(ticketA, SELECT_BY_TICKET))
            PlaceRefillOrders("B", OrderOpenPrice());
      }
      else if(hasB && !hasA && !pendA && ticketB != -1)
      {
         if(OrderSelect(ticketB, SELECT_BY_TICKET))
            PlaceRefillOrders("A", OrderOpenPrice());
      }
   }

   state_A = nextA;
   state_B = nextB;

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

   int err;
   if(!SaveDMCState("A", stateA, err))
   {
      LogRecord rec;
      rec.Time      = TimeCurrent();
      rec.Symbol    = Symbol();
      rec.System    = "A";
      rec.Reason    = "STATE_SAVE_FAIL";
      rec.Spread    = 0;
      rec.Dist      = 0;
      rec.GridPips  = GridPips;
      rec.s         = s;
      rec.lotFactor = 0;
      rec.BaseLot   = BaseLot;
      rec.MaxLot    = MaxLot;
      rec.actualLot = 0;
      rec.seqStr    = "";
      rec.CommentTag= "";
      rec.Magic     = MagicNumber;
      rec.OrderType = "";
      rec.EntryPrice= 0;
      rec.SL        = 0;
      rec.TP        = 0;
      rec.ErrorCode = err;
      WriteLog(rec);
   }

   if(!SaveDMCState("B", stateB, err))
   {
      LogRecord rec;
      rec.Time      = TimeCurrent();
      rec.Symbol    = Symbol();
      rec.System    = "B";
      rec.Reason    = "STATE_SAVE_FAIL";
      rec.Spread    = 0;
      rec.Dist      = 0;
      rec.GridPips  = GridPips;
      rec.s         = s;
      rec.lotFactor = 0;
      rec.BaseLot   = BaseLot;
      rec.MaxLot    = MaxLot;
      rec.actualLot = 0;
      rec.seqStr    = "";
      rec.CommentTag= "";
      rec.Magic     = MagicNumber;
      rec.OrderType = "";
      rec.EntryPrice= 0;
      rec.SL        = 0;
      rec.TP        = 0;
      rec.ErrorCode = err;
      WriteLog(rec);
   }
}

