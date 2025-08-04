#property strict

#include "DecompositionMonteCarloMM.mqh"

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
   int lotDigits = 0;
   if(lotStep > 0)
   {
      lot = MathRound(lot / lotStep) * lotStep;
      lotDigits = (int)MathRound(-MathLog10(lotStep));
      lot = NormalizeDouble(lot, lotDigits);
   }

   if(lot < minLot)
      lot = minLot;
   if(lot > maxLot)
      lot = maxLot;
   if(lot > MaxLot)
      lot = MaxLot;

   return(NormalizeDouble(lot, lotDigits));
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

      int prevN=0;
      ResetLastError(); double prevSize=GlobalVariableGet(prefix+"seq_size"); int e=GetLastError();
      if(e==0) prevN=(int)prevSize;

      for(int i=n;i<prevN;i++)
      {
         string name=prefix+"seq_"+IntegerToString(i);
         ResetLastError(); GlobalVariableDel(name); e=GetLastError(); if(e!=0){if(err==0)err=e; ok=false;}
      }

      ResetLastError(); GlobalVariableSet(prefix+"stock",stock); e=GetLastError(); if(e!=0){if(err==0)err=e; ok=false;}
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
//| Calculate distance (pips) from a price to existing positions      |
//| Pending orders are ignored; distance band is position-based       |
//| 未決済注文は距離計算に含めず、距離帯判定はポジションベース     |
//| Returns -1 if there are no existing positions                    |
//+------------------------------------------------------------------+
double DistanceToExistingPositions(const double price)
{
   double minDist = DBL_MAX;
   for(int i = OrdersTotal()-1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderMagicNumber() != MagicNumber || OrderSymbol() != Symbol())
         continue;
      int type = OrderType();
      // 成行ポジションのみを距離計算に含める（未決済注文は除外）
      if(type != OP_BUY && type != OP_SELL)
         continue;
      double d = MathAbs(price - OrderOpenPrice());
      if(d < minDist)
         minDist = d;
   }
   if(minDist == DBL_MAX)
      return(-1);
   return PriceToPips(minDist);
}

//+------------------------------------------------------------------+
//| Check spread and distance band for a candidate order price       |
//| refPrice: entry price of the other system for distance band      |
//+------------------------------------------------------------------+
bool CanPlaceOrder(double &price,const bool isBuy,const double refPrice)
{
   RefreshRates();

   double stopLevel   = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
   double freezeLevel = MarketInfo(Symbol(), MODE_FREEZELEVEL) * Point;

   // 注文方向に応じた基準価格を取得
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
      price = isBuy ? ref - stopLevel : ref + stopLevel;
      price = NormalizeDouble(price, Digits);
      PrintFormat("CanPlaceOrder: price adjusted from %.5f to %.5f due to stop level %.1f pips",
                  oldPrice, price, PriceToPips(stopLevel));

      // StopLevel 補正後に距離を再計算し、FreezeLevel を再チェック
      dist = MathAbs(price - ref);
      if(dist < freezeLevel)
      {
         PrintFormat("CanPlaceOrder: price %.5f within freeze level %.1f pips after stop adjustment, retry next tick",
                     price, PriceToPips(freezeLevel));
         return(false);
      }
   }

   double spread = PriceToPips(Ask - Bid);
   if(spread > MaxSpreadPips)
   {
      PrintFormat("Spread %.1f exceeds MaxSpreadPips %.1f", spread, MaxSpreadPips);
      return(false);
   }

   if(UseDistanceBand)
   {
      double bandDist = PriceToPips(MathAbs(price - refPrice));
      if(bandDist < MinDistancePips || bandDist > MaxDistancePips)
      {
         PrintFormat("Distance %.1f outside band [%.1f, %.1f]", bandDist, MinDistancePips, MaxDistancePips);
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
   return StringFormat("MoveCatcher_%s_%s", system, seq);
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
//| updateDMC=false で DMCMM 状態更新を抑制しログのみ残す           |
//+------------------------------------------------------------------+
void ProcessClosedTrades(const string system,const bool updateDMC)
{
   RefreshRates();
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
      int type  = OrderType();
      if(system == "A")
      {
         if(updateDMC)
            stateA.OnTrade(win);
         if(times[i] > lastCloseTimeA)
            lastCloseTimeA = times[i];
      }
      else
      {
         if(updateDMC)
            stateB.OnTrade(win);
         if(times[i] > lastCloseTimeB)
            lastCloseTimeB = times[i];
      }

      string sysTmp, seq;
      if(!ParseComment(OrderComment(), sysTmp, seq))
         seq = "";
      double closePrice = OrderClosePrice();
      double tol        = Point * 0.5;
      bool isTP = (MathAbs(closePrice - OrderTakeProfit()) <= tol);
      bool isSL = (MathAbs(closePrice - OrderStopLoss())  <= tol);
      string reason = isTP ? "TP" : "SL";
      if(!isTP && !isSL)
         reason = (profit >= 0) ? "TP" : "SL";
      LogRecord lr;
      lr.Time       = times[i];
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
      lr.ErrorCode  = 0;
      WriteLog(lr);
   }
}

//+------------------------------------------------------------------+
//| Find existing shadow pending order for a position                |
//+------------------------------------------------------------------+
bool FindShadowPending(const string system,const double entry,const bool isBuy,
                      int &ticket,double &lot,string &comment)
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
            ticket  = OrderTicket();
            lot     = OrderLots();
            comment = OrderComment();
            return(true);
         }
      }
   }
   ticket  = -1;
   lot     = 0;
   comment = "";
   return(false);
}

//+------------------------------------------------------------------+
//| Ensure TP/SL are set for a position                              |
//+------------------------------------------------------------------+
void EnsureTPSL(const int ticket)
{
   RefreshRates();
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

         string sys, seq;
         ParseComment(OrderComment(), sys, seq);
         LogRecord lr;
         lr.Time       = TimeCurrent();
         lr.Symbol     = Symbol();
         lr.System     = sys;
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
         lr.EntryPrice = entry;
         lr.SL         = desiredSL;
         lr.TP         = desiredTP;
         lr.ErrorCode  = err;
         WriteLog(lr);
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
   string seq;
   double lotFactor;
   double lot = CalcLot(system, seq, lotFactor);
   if(lot <= 0)
      return;
   string comment = MakeComment(system, seq);

   int    pendTicket;
   double pendLot;
   string pendComment;
   if(FindShadowPending(system, entry, isBuy, pendTicket, pendLot, pendComment))
   {
      double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);
      double lotTol  = (lotStep > 0) ? lotStep * 0.5 : 1e-8;
      if(MathAbs(pendLot - lot) <= lotTol && pendComment == comment)
         return; // already exists with expected lot/comment

      int pendType  = isBuy ? OP_SELLLIMIT : OP_BUYLIMIT;
      double pendPrice = isBuy ? entry + PipsToPrice(GridPips)
                               : entry - PipsToPrice(GridPips);
      if(OrderSelect(pendTicket, SELECT_BY_TICKET))
      {
         pendType  = OrderType();
         pendPrice = OrderOpenPrice();
      }
      int err = 0;
      bool ok = OrderDelete(pendTicket);
      if(!ok)
         err = GetLastError();

      LogRecord lru;
      lru.Time       = TimeCurrent();
      lru.Symbol     = Symbol();
      lru.System     = system;
      // REFILL: 影指値の更新
      lru.Reason     = "REFILL";
      lru.Spread     = PriceToPips(Ask - Bid);
      lru.Dist       = GridPips;
      lru.GridPips   = GridPips;
      lru.s          = s;
      lru.lotFactor  = 0;
      lru.BaseLot    = BaseLot;
      lru.MaxLot     = MaxLot;
      lru.actualLot  = pendLot;
      lru.seqStr     = "";
      lru.CommentTag = pendComment;
      lru.Magic      = MagicNumber;
      lru.OrderType  = OrderTypeToStr(pendType);
      lru.EntryPrice = pendPrice;
      lru.SL         = 0;
      lru.TP         = 0;
      lru.ErrorCode  = err;
      WriteLog(lru);
      if(!ok)
      {
         PrintFormat("EnsureShadowOrder: failed to delete shadow order for %s err=%d", system, err);
         return;
      }
      PrintFormat("EnsureShadowOrder: replaced shadow order for %s", system);
   }

   double price = isBuy ? entry + PipsToPrice(GridPips)
                        : entry - PipsToPrice(GridPips);
   price = NormalizeDouble(price, Digits);
   int type = isBuy ? OP_SELLLIMIT : OP_BUYLIMIT;

   RefreshRates();
   double stopLevel   = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
   double freezeLevel = MarketInfo(Symbol(), MODE_FREEZELEVEL) * Point;
   double ref         = (type == OP_BUYLIMIT) ? Ask : Bid;
   double dist        = MathAbs(price - ref);
   if(dist < freezeLevel)
   {
      LogRecord lrf;
      lrf.Time       = TimeCurrent();
      lrf.Symbol     = Symbol();
      lrf.System     = system;
      lrf.Reason     = "REFILL";
      lrf.Spread     = PriceToPips(Ask - Bid);
      lrf.Dist       = GridPips;
      lrf.GridPips   = GridPips;
      lrf.s          = s;
      lrf.lotFactor  = lotFactor;
      lrf.BaseLot    = BaseLot;
      lrf.MaxLot     = MaxLot;
      lrf.actualLot  = lot;
      lrf.seqStr     = seq;
      lrf.CommentTag = comment;
      lrf.Magic      = MagicNumber;
      lrf.OrderType  = OrderTypeToStr(type);
      lrf.EntryPrice = price;
      lrf.SL         = 0;
      lrf.TP         = 0;
      // Freeze level violation
      lrf.ErrorCode  = 145;
      WriteLog(lrf);
      PrintFormat("EnsureShadowOrder: price %.5f within freeze level %.1f pips, retry next tick", price, PriceToPips(freezeLevel));
      return;
   }
   if(dist < stopLevel)
   {
      LogRecord lrs;
      lrs.Time       = TimeCurrent();
      lrs.Symbol     = Symbol();
      lrs.System     = system;
      lrs.Reason     = "REFILL";
      lrs.Spread     = PriceToPips(Ask - Bid);
      lrs.Dist       = GridPips;
      lrs.GridPips   = GridPips;
      lrs.s          = s;
      lrs.lotFactor  = lotFactor;
      lrs.BaseLot    = BaseLot;
      lrs.MaxLot     = MaxLot;
      lrs.actualLot  = lot;
      lrs.seqStr     = seq;
      lrs.CommentTag = comment;
      lrs.Magic      = MagicNumber;
      lrs.OrderType  = OrderTypeToStr(type);
      lrs.EntryPrice = price;
      lrs.SL         = 0;
      lrs.TP         = 0;
      // Stop level violation
      lrs.ErrorCode  = 130;
      WriteLog(lrs);
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
      double lots = OrderLots();
      double entry = OrderOpenPrice();
      double sl    = OrderStopLoss();
      double tp    = OrderTakeProfit();
      string comment = OrderComment();
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
      lr.actualLot  = lots;
      lr.seqStr     = seq;
      lr.CommentTag = comment;
      lr.Magic      = MagicNumber;
      lr.OrderType  = OrderTypeToStr(type);
      lr.EntryPrice = entry;
      lr.SL         = sl;
      lr.TP         = tp;
      lr.ErrorCode  = err;
      WriteLog(lr);
      if(!ok)
         PrintFormat("DeletePendings: failed to delete %d err=%d", tk, err);
   }
}

//+------------------------------------------------------------------+
//| Re-enter position after SL. When UseProtectedLimit=false,         |
//| slippage protection is disabled (slippage=0).                     |
//+------------------------------------------------------------------+
void RecoverAfterSL(const string system)
{
   RefreshRates();
   ProcessClosedTrades(system, true);
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
   int    slippage = UseProtectedLimit ? (int)MathRound(SlippagePips * Pip() / Point) : 0;
   double price    = isBuy ? Ask : Bid;
   double sl       = NormalizeDouble(isBuy ? price - PipsToPrice(GridPips) : price + PipsToPrice(GridPips), Digits);
   double tp       = NormalizeDouble(isBuy ? price + PipsToPrice(GridPips) : price - PipsToPrice(GridPips), Digits);
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
   double dist     = DistanceToExistingPositions(price);
   if(UseDistanceBand && dist >= 0 && (dist < MinDistancePips || dist > MaxDistancePips))
   {
      LogRecord lrSkip;
      lrSkip.Time       = TimeCurrent();
      lrSkip.Symbol     = Symbol();
      lrSkip.System     = system;
      lrSkip.Reason     = "SL";
      lrSkip.Spread     = PriceToPips(Ask - Bid);
      lrSkip.Dist       = dist;
      lrSkip.GridPips   = GridPips;
      lrSkip.s          = s;
      lrSkip.lotFactor  = lotFactor;
      lrSkip.BaseLot    = BaseLot;
      lrSkip.MaxLot     = MaxLot;
      lrSkip.actualLot  = lot;
      lrSkip.seqStr     = seq;
      lrSkip.CommentTag = comment;
      lrSkip.Magic      = MagicNumber;
      lrSkip.OrderType  = OrderTypeToStr(isBuy ? OP_BUY : OP_SELL);
      lrSkip.EntryPrice = price;
      lrSkip.SL         = sl;
      lrSkip.TP         = tp;
      lrSkip.ErrorCode  = 0;
      WriteLog(lrSkip);
      PrintFormat("RecoverAfterSL: distance %.1f outside band [%.1f, %.1f], order skipped",
                  dist, MinDistancePips, MaxDistancePips);
      return;
   }
   int type        = isBuy ? OP_BUY : OP_SELL;
   int ticket      = OrderSend(Symbol(), type, lot, price,
                               slippage, sl, tp, comment, MagicNumber, 0, clrNONE);
   LogRecord lr;
   lr.Time       = TimeCurrent();
   lr.Symbol     = Symbol();
   lr.System     = system;
   lr.Reason     = "SL";
   lr.Spread     = PriceToPips(Ask - Bid);
    lr.Dist       = (dist >= 0) ? dist : 0;
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
   lr.SL         = sl;
   lr.TP         = tp;
   lr.ErrorCode  = (ticket < 0) ? GetLastError() : 0;
   WriteLog(lr);
   if(ticket < 0)
   {
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
   lr.EntryPrice = entry;
   lr.SL         = desiredSL;
   lr.TP         = desiredTP;
   int err = 0;
   if(!OrderModify(ticket, entry, desiredSL, desiredTP, 0, clrNONE))
   {
      err = GetLastError();
      lr.ErrorCode = err;
      WriteLog(lr);
      PrintFormat("RecoverAfterSL: failed to adjust TP/SL for %s ticket %d err=%d", system, ticket, err);
      if(system == "A")
         retryTicketA = ticket;
      else
         retryTicketB = ticket;
   }
   else
   {
      lr.ErrorCode = 0;
      WriteLog(lr);
      if(system == "A")
         retryTicketA = -1;
      else
         retryTicketB = -1;
   }

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
            ProcessClosedTrades(sysTmp, true);
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
   if(!updateDMC)
      InitCloseTimes();
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
      ProcessClosedTrades("A", false);
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
      ProcessClosedTrades("B", false);
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
   int ticketSell = -1;
   int ticketBuy  = -1;
   bool okSell = true;
   bool okBuy  = true;

   double distSell = MathAbs(Bid - priceSell);
   if(distSell < freezeLevel)
   {
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
      lr.ErrorCode  = 145;
      WriteLog(lr);
      PrintFormat("PlaceRefillOrders: SellLimit %.5f within freeze level %.1f pips, retry next tick",
                  priceSell, PriceToPips(freezeLevel));
      okSell = false;
   }
   else
   {
      if(distSell < stopLevel)
      {
         double old = priceSell;
         priceSell = NormalizeDouble(Bid + stopLevel, Digits);
         PrintFormat("PlaceRefillOrders: SellLimit adjusted from %.5f to %.5f due to stop level %.1f pips",
                     old, priceSell, PriceToPips(stopLevel));
      }
      if(!CanPlaceOrder(priceSell, false, refPrice))
      {
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
         // Spread or band violation
         lr.ErrorCode  = (PriceToPips(Ask - Bid) > MaxSpreadPips) ? 4109 : 0;
         WriteLog(lr);
         okSell = false;
      }
      else
      {
         ticketSell = OrderSend(Symbol(), OP_SELLLIMIT, lot, priceSell,
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
         {
            PrintFormat("PlaceRefillOrders: failed to place SellLimit for %s err=%d", system, lr.ErrorCode);
            okSell = false;
         }
      }
   }

   double distBuy = MathAbs(Ask - priceBuy);
   if(distBuy < freezeLevel)
   {
      LogRecord lrb;
      lrb.Time       = TimeCurrent();
      lrb.Symbol     = Symbol();
      lrb.System     = system;
      lrb.Reason     = "REFILL";
      lrb.Spread     = PriceToPips(Ask - Bid);
      lrb.Dist       = PriceToPips(MathAbs(priceBuy - refPrice));
      lrb.GridPips   = GridPips;
      lrb.s          = s;
      lrb.lotFactor  = lotFactor;
      lrb.BaseLot    = BaseLot;
      lrb.MaxLot     = MaxLot;
      lrb.actualLot  = lot;
      lrb.seqStr     = seq;
      lrb.CommentTag = comment;
      lrb.Magic      = MagicNumber;
      lrb.OrderType  = OrderTypeToStr(OP_BUYLIMIT);
      lrb.EntryPrice = priceBuy;
      lrb.SL         = 0;
      lrb.TP         = 0;
      lrb.ErrorCode  = 145;
      WriteLog(lrb);
      PrintFormat("PlaceRefillOrders: BuyLimit %.5f within freeze level %.1f pips, retry next tick",
                  priceBuy, PriceToPips(freezeLevel));
      okBuy = false;
   }
   else
   {
      if(distBuy < stopLevel)
      {
         double oldB = priceBuy;
         priceBuy = NormalizeDouble(Ask - stopLevel, Digits);
         PrintFormat("PlaceRefillOrders: BuyLimit adjusted from %.5f to %.5f due to stop level %.1f pips",
                     oldB, priceBuy, PriceToPips(stopLevel));
      }
      if(!CanPlaceOrder(priceBuy, true, refPrice))
      {
         LogRecord lrb;
         lrb.Time       = TimeCurrent();
         lrb.Symbol     = Symbol();
         lrb.System     = system;
         lrb.Reason     = "REFILL";
         lrb.Spread     = PriceToPips(Ask - Bid);
         lrb.Dist       = PriceToPips(MathAbs(priceBuy - refPrice));
         lrb.GridPips   = GridPips;
         lrb.s          = s;
         lrb.lotFactor  = lotFactor;
         lrb.BaseLot    = BaseLot;
         lrb.MaxLot     = MaxLot;
         lrb.actualLot  = lot;
         lrb.seqStr     = seq;
         lrb.CommentTag = comment;
         lrb.Magic      = MagicNumber;
         lrb.OrderType  = OrderTypeToStr(OP_BUYLIMIT);
         lrb.EntryPrice = priceBuy;
         lrb.SL         = 0;
         lrb.TP         = 0;
         lrb.ErrorCode  = (PriceToPips(Ask - Bid) > MaxSpreadPips) ? 4109 : 0;
         WriteLog(lrb);
         okBuy = false;
      }
      else
      {
         ticketBuy = OrderSend(Symbol(), OP_BUYLIMIT, lot, priceBuy,
                               0, 0, 0, comment, MagicNumber, 0, clrNONE);
         LogRecord lr2;
         lr2.Time       = TimeCurrent();
         lr2.Symbol     = Symbol();
         lr2.System     = system;
         lr2.Reason     = "REFILL";
         lr2.Spread     = PriceToPips(Ask - Bid);
         lr2.Dist       = PriceToPips(MathAbs(priceBuy - refPrice));
         lr2.GridPips   = GridPips;
         lr2.s          = s;
         lr2.lotFactor  = lotFactor;
         lr2.BaseLot    = BaseLot;
         lr2.MaxLot     = MaxLot;
         lr2.actualLot  = lot;
         lr2.seqStr     = seq;
         lr2.CommentTag = comment;
         lr2.Magic      = MagicNumber;
         lr2.OrderType  = OrderTypeToStr(OP_BUYLIMIT);
         lr2.EntryPrice = priceBuy;
         lr2.SL         = 0;
         lr2.TP         = 0;
         lr2.ErrorCode  = (ticketBuy < 0) ? GetLastError() : 0;
         WriteLog(lr2);
         if(ticketBuy < 0)
         {
            PrintFormat("PlaceRefillOrders: failed to place BuyLimit for %s err=%d", system, lr2.ErrorCode);
            okBuy = false;
         }
      }
   }

   if(okSell && !okBuy && ticketSell >= 0)
   {
      int err = 0;
      bool delOk = OrderDelete(ticketSell);
      if(!delOk)
         err = GetLastError();

      LogRecord lrd;
      lrd.Time       = TimeCurrent();
      lrd.Symbol     = Symbol();
      lrd.System     = system;
      lrd.Reason     = "REFILL";
      lrd.Spread     = PriceToPips(Ask - Bid);
      lrd.Dist       = PriceToPips(MathAbs(priceSell - refPrice));
      lrd.GridPips   = GridPips;
      lrd.s          = s;
      lrd.lotFactor  = lotFactor;
      lrd.BaseLot    = BaseLot;
      lrd.MaxLot     = MaxLot;
      lrd.actualLot  = lot;
      lrd.seqStr     = seq;
      lrd.CommentTag = comment;
      lrd.Magic      = MagicNumber;
      lrd.OrderType  = OrderTypeToStr(OP_SELLLIMIT);
      lrd.EntryPrice = priceSell;
      lrd.SL         = 0;
      lrd.TP         = 0;
      lrd.ErrorCode  = err;
      WriteLog(lrd);
      if(delOk)
         PrintFormat("PlaceRefillOrders: canceled SellLimit due to BuyLimit failure for %s", system);
      else
         PrintFormat("PlaceRefillOrders: failed to delete SellLimit for %s err=%d", system, err);
   }
   if(okBuy && !okSell && ticketBuy >= 0)
   {
      int err = 0;
      bool delOk = OrderDelete(ticketBuy);
      if(!delOk)
         err = GetLastError();

      LogRecord lrd;
      lrd.Time       = TimeCurrent();
      lrd.Symbol     = Symbol();
      lrd.System     = system;
      lrd.Reason     = "REFILL";
      lrd.Spread     = PriceToPips(Ask - Bid);
      lrd.Dist       = PriceToPips(MathAbs(priceBuy - refPrice));
      lrd.GridPips   = GridPips;
      lrd.s          = s;
      lrd.lotFactor  = lotFactor;
      lrd.BaseLot    = BaseLot;
      lrd.MaxLot     = MaxLot;
      lrd.actualLot  = lot;
      lrd.seqStr     = seq;
      lrd.CommentTag = comment;
      lrd.Magic      = MagicNumber;
      lrd.OrderType  = OrderTypeToStr(OP_BUYLIMIT);
      lrd.EntryPrice = priceBuy;
      lrd.SL         = 0;
      lrd.TP         = 0;
      lrd.ErrorCode  = err;
      WriteLog(lrd);
      if(delOk)
         PrintFormat("PlaceRefillOrders: canceled BuyLimit due to SellLimit failure for %s", system);
      else
         PrintFormat("PlaceRefillOrders: failed to delete BuyLimit for %s err=%d", system, err);
   }
}

//+------------------------------------------------------------------+
//| Place initial market order for system A and OCO limits for B     |
//+------------------------------------------------------------------+
bool InitStrategy()
{
   RefreshRates();

   //---- system A market order
   string seqA; double lotFactorA; double lotA = CalcLot("A", seqA, lotFactorA);
   if(lotA <= 0) return(false);

   bool isBuy = (MathRand() % 2) == 0;
   int    slippage = (int)MathRound(SlippagePips * Pip() / Point);
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
   double distA    = DistanceToExistingPositions(price);
   if(UseDistanceBand && distA >= 0 && (distA < MinDistancePips || distA > MaxDistancePips))
   {
      LogRecord lrSkipA;
      lrSkipA.Time       = TimeCurrent();
      lrSkipA.Symbol     = Symbol();
      lrSkipA.System     = "A";
      lrSkipA.Reason     = "INIT";
      lrSkipA.Spread     = PriceToPips(Ask - Bid);
      lrSkipA.Dist       = distA;
      lrSkipA.GridPips   = GridPips;
      lrSkipA.s          = s;
      lrSkipA.lotFactor  = lotFactorA;
      lrSkipA.BaseLot    = BaseLot;
      lrSkipA.MaxLot     = MaxLot;
      lrSkipA.actualLot  = lotA;
      lrSkipA.seqStr     = seqA;
      lrSkipA.CommentTag = commentA;
      lrSkipA.Magic      = MagicNumber;
      lrSkipA.OrderType  = OrderTypeToStr(isBuy ? OP_BUY : OP_SELL);
      lrSkipA.EntryPrice = price;
      lrSkipA.SL         = entrySL;
      lrSkipA.TP         = entryTP;
      lrSkipA.ErrorCode  = 0;
      WriteLog(lrSkipA);
      PrintFormat("InitStrategy: distance %.1f outside band [%.1f, %.1f], order skipped",
                  distA, MinDistancePips, MaxDistancePips);
      return(false);
   }
   int typeA   = isBuy ? OP_BUY : OP_SELL;
   int ticketA = OrderSend(Symbol(), typeA, lotA, price,
                           slippage, entrySL, entryTP, commentA, MagicNumber, 0, clrNONE);
   LogRecord lrA;
   lrA.Time       = TimeCurrent();
   lrA.Symbol     = Symbol();
   lrA.System     = "A";
   lrA.Reason     = "INIT";
   lrA.Spread     = PriceToPips(Ask - Bid);
   lrA.Dist       = (distA >= 0) ? distA : 0;
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
      return(false);
   }

   if(!OrderSelect(ticketA, SELECT_BY_TICKET))
      return(false);
   double entryPrice = OrderOpenPrice();

   EnsureShadowOrder(ticketA, "A");

   //---- system B OCO pending orders
   string seqB; double lotFactorB; double lotB = CalcLot("B", seqB, lotFactorB);
   if(lotB <= 0) return(false);
   string commentB = MakeComment("B", seqB);

   double priceSell = entryPrice + PipsToPrice(s);
   double priceBuy  = entryPrice - PipsToPrice(s);
   stopLevel   = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
   freezeLevel = MarketInfo(Symbol(), MODE_FREEZELEVEL) * Point;

   int ticketSell = -1;
   int ticketBuy  = -1;
   bool okSell = true;
   bool okBuy  = true;
   double distSell = MathAbs(Bid - priceSell);
   if(distSell < freezeLevel)
   {
      double distBand = DistanceToExistingPositions(priceSell);
      LogRecord lrS;
      lrS.Time       = TimeCurrent();
      lrS.Symbol     = Symbol();
      lrS.System     = "B";
      lrS.Reason     = "INIT";
      lrS.Spread     = PriceToPips(Ask - Bid);
      lrS.Dist       = (distBand >= 0) ? distBand : 0;
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
      lrS.ErrorCode  = 145;
      WriteLog(lrS);
      PrintFormat("InitStrategy: SellLimit %.5f within freeze level %.1f pips, retry next tick",
                  priceSell, PriceToPips(freezeLevel));
      okSell = false;
   }
   else
   {
      if(distSell < stopLevel)
      {
         double oldS = priceSell;
         priceSell = NormalizeDouble(Bid + stopLevel, Digits);
         PrintFormat("InitStrategy: SellLimit adjusted from %.5f to %.5f due to stop level %.1f pips",
                     oldS, priceSell, PriceToPips(stopLevel));
      }
      double distBand = DistanceToExistingPositions(priceSell);
      if(UseDistanceBand && distBand >= 0 && (distBand < MinDistancePips || distBand > MaxDistancePips))
      {
         LogRecord lrS;
         lrS.Time       = TimeCurrent();
         lrS.Symbol     = Symbol();
         lrS.System     = "B";
         lrS.Reason     = "INIT";
         lrS.Spread     = PriceToPips(Ask - Bid);
         lrS.Dist       = distBand;
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
         lrS.ErrorCode  = 0;
         WriteLog(lrS);
         PrintFormat("InitStrategy: SellLimit distance %.1f outside band [%.1f, %.1f]",
                     distBand, MinDistancePips, MaxDistancePips);
         okSell = false;
      }
      else if(!CanPlaceOrder(priceSell, false, entryPrice))
      {
         LogRecord lrS;
         lrS.Time       = TimeCurrent();
         lrS.Symbol     = Symbol();
         lrS.System     = "B";
         lrS.Reason     = "INIT";
         lrS.Spread     = PriceToPips(Ask - Bid);
         lrS.Dist       = distBand;
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
         lrS.ErrorCode  = (PriceToPips(Ask - Bid) > MaxSpreadPips) ? 4109 : 0;
         WriteLog(lrS);
         okSell = false;
      }
      else
      {
         ticketSell = OrderSend(Symbol(), OP_SELLLIMIT, lotB, priceSell,
                                0, 0, 0, commentB, MagicNumber, 0, clrNONE);
         LogRecord lrS;
         lrS.Time       = TimeCurrent();
         lrS.Symbol     = Symbol();
         lrS.System     = "B";
         lrS.Reason     = "INIT";
         lrS.Spread     = PriceToPips(Ask - Bid);
         lrS.Dist       = distBand;
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
         {
            PrintFormat("InitStrategy: failed to place SellLimit, err=%d", lrS.ErrorCode);
            okSell = false;
         }
      }
   }

   double distBuy = MathAbs(Ask - priceBuy);
   if(distBuy < freezeLevel)
   {
      double distBandB = DistanceToExistingPositions(priceBuy);
      LogRecord lrB;
      lrB.Time       = TimeCurrent();
      lrB.Symbol     = Symbol();
      lrB.System     = "B";
      lrB.Reason     = "INIT";
      lrB.Spread     = PriceToPips(Ask - Bid);
      lrB.Dist       = (distBandB >= 0) ? distBandB : 0;
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
      lrB.ErrorCode  = 145;
      WriteLog(lrB);
      PrintFormat("InitStrategy: BuyLimit %.5f within freeze level %.1f pips, retry next tick",
                  priceBuy, PriceToPips(freezeLevel));
      okBuy = false;
   }
   else
   {
      if(distBuy < stopLevel)
      {
         double oldB = priceBuy;
         priceBuy = NormalizeDouble(Ask - stopLevel, Digits);
         PrintFormat("InitStrategy: BuyLimit adjusted from %.5f to %.5f due to stop level %.1f pips",
                     oldB, priceBuy, PriceToPips(stopLevel));
      }
      double distBandB = DistanceToExistingPositions(priceBuy);
      if(UseDistanceBand && distBandB >= 0 && (distBandB < MinDistancePips || distBandB > MaxDistancePips))
      {
         LogRecord lrB;
         lrB.Time       = TimeCurrent();
         lrB.Symbol     = Symbol();
         lrB.System     = "B";
         lrB.Reason     = "INIT";
         lrB.Spread     = PriceToPips(Ask - Bid);
         lrB.Dist       = distBandB;
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
         lrB.ErrorCode  = 0;
         WriteLog(lrB);
         PrintFormat("InitStrategy: BuyLimit distance %.1f outside band [%.1f, %.1f]",
                     distBandB, MinDistancePips, MaxDistancePips);
         okBuy = false;
      }
      else if(!CanPlaceOrder(priceBuy, true, entryPrice))
      {
         LogRecord lrB;
         lrB.Time       = TimeCurrent();
         lrB.Symbol     = Symbol();
         lrB.System     = "B";
         lrB.Reason     = "INIT";
         lrB.Spread     = PriceToPips(Ask - Bid);
         lrB.Dist       = distBandB;
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
         lrB.ErrorCode  = (PriceToPips(Ask - Bid) > MaxSpreadPips) ? 4109 : 0;
         WriteLog(lrB);
         okBuy = false;
      }
      else
      {
         ticketBuy = OrderSend(Symbol(), OP_BUYLIMIT, lotB, priceBuy,
                               0, 0, 0, commentB, MagicNumber, 0, clrNONE);
         LogRecord lrB;
         lrB.Time       = TimeCurrent();
         lrB.Symbol     = Symbol();
         lrB.System     = "B";
         lrB.Reason     = "INIT";
         lrB.Spread     = PriceToPips(Ask - Bid);
         lrB.Dist       = distBandB;
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
         {
            PrintFormat("InitStrategy: failed to place BuyLimit, err=%d", lrB.ErrorCode);
            okBuy = false;
         }
      }
   }

   if(okSell && !okBuy && ticketSell >= 0)
   {
      int err = 0;
      bool delOk = OrderDelete(ticketSell);
      if(!delOk)
         err = GetLastError();

      LogRecord lrd;
      lrd.Time       = TimeCurrent();
      lrd.Symbol     = Symbol();
      lrd.System     = "B";
      lrd.Reason     = "INIT";
      lrd.Spread     = PriceToPips(Ask - Bid);
      lrd.Dist       = DistanceToExistingPositions(priceSell);
      lrd.GridPips   = GridPips;
      lrd.s          = s;
      lrd.lotFactor  = lotFactorB;
      lrd.BaseLot    = BaseLot;
      lrd.MaxLot     = MaxLot;
      lrd.actualLot  = lotB;
      lrd.seqStr     = seqB;
      lrd.CommentTag = commentB;
      lrd.Magic      = MagicNumber;
      lrd.OrderType  = OrderTypeToStr(OP_SELLLIMIT);
      lrd.EntryPrice = priceSell;
      lrd.SL         = 0;
      lrd.TP         = 0;
      lrd.ErrorCode  = err;
      WriteLog(lrd);
      if(delOk)
         Print("InitStrategy: SellLimit canceled due to BuyLimit failure");
      else
         PrintFormat("InitStrategy: failed to delete SellLimit err=%d", err);
      return(false);
   }
   if(okBuy && !okSell && ticketBuy >= 0)
   {
      int err = 0;
      bool delOk = OrderDelete(ticketBuy);
      if(!delOk)
         err = GetLastError();

      LogRecord lrd;
      lrd.Time       = TimeCurrent();
      lrd.Symbol     = Symbol();
      lrd.System     = "B";
      lrd.Reason     = "INIT";
      lrd.Spread     = PriceToPips(Ask - Bid);
      lrd.Dist       = DistanceToExistingPositions(priceBuy);
      lrd.GridPips   = GridPips;
      lrd.s          = s;
      lrd.lotFactor  = lotFactorB;
      lrd.BaseLot    = BaseLot;
      lrd.MaxLot     = MaxLot;
      lrd.actualLot  = lotB;
      lrd.seqStr     = seqB;
      lrd.CommentTag = commentB;
      lrd.Magic      = MagicNumber;
      lrd.OrderType  = OrderTypeToStr(OP_BUYLIMIT);
      lrd.EntryPrice = priceBuy;
      lrd.SL         = 0;
      lrd.TP         = 0;
      lrd.ErrorCode  = err;
      WriteLog(lrd);
      if(delOk)
         Print("InitStrategy: BuyLimit canceled due to SellLimit failure");
      else
         PrintFormat("InitStrategy: failed to delete BuyLimit err=%d", err);
      return(false);
   }

   return(okBuy && okSell);
  }

//+------------------------------------------------------------------+
//| Detect filled OCO for specified system                            |
//+------------------------------------------------------------------+
void HandleOCODetectionFor(const string system)
{
   ProcessClosedTrades(system, true);
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

   string seqAdj; double lotFactorAdj;
   double expectedLot = CalcLot(system, seqAdj, lotFactorAdj);
   if(expectedLot <= 0)
   {
      string tmpComment = MakeComment(system, seqAdj);
      bool shouldLog = true;
      if(system == "A")
      {
         if(retryTicketA == posTicket)
            shouldLog = false;
         retryTicketA = posTicket;
      }
      else
      {
         if(retryTicketB == posTicket)
            shouldLog = false;
         retryTicketB = posTicket;
      }
      if(shouldLog)
      {
         LogRecord lrSkip;
         lrSkip.Time       = TimeCurrent();
         lrSkip.Symbol     = Symbol();
         lrSkip.System     = system;
         lrSkip.Reason     = "REFILL";
         lrSkip.Spread     = PriceToPips(Ask - Bid);
         lrSkip.Dist       = 0;
         lrSkip.GridPips   = GridPips;
         lrSkip.s          = s;
         lrSkip.lotFactor  = lotFactorAdj;
         lrSkip.BaseLot    = BaseLot;
         lrSkip.MaxLot     = MaxLot;
         lrSkip.actualLot  = 0;
         lrSkip.seqStr     = seqAdj;
         lrSkip.CommentTag = tmpComment;
         lrSkip.Magic      = MagicNumber;
         lrSkip.OrderType  = "";
         lrSkip.EntryPrice = 0;
         lrSkip.SL         = 0;
         lrSkip.TP         = 0;
         lrSkip.ErrorCode  = 0;
         WriteLog(lrSkip);
      }
      return;
   }
   string expectedComment = MakeComment(system, seqAdj);
   if(MathAbs(OrderLots() - expectedLot) > 1e-8 || OrderComment() != expectedComment)
   {
      RefreshRates();
      int    type      = OrderType();
      double oldLots   = OrderLots();
      double closePrice = (type == OP_BUY) ? Bid : Ask;
      string sysTmp, oldSeq; ParseComment(OrderComment(), sysTmp, oldSeq);
      int errClose = 0;
      if(!OrderClose(posTicket, oldLots, closePrice, 0, clrNONE))
         errClose = GetLastError();
      LogRecord lrClose;
      lrClose.Time       = TimeCurrent();
      lrClose.Symbol     = Symbol();
      lrClose.System     = system;
      lrClose.Reason     = "REFILL";
      lrClose.Spread     = PriceToPips(Ask - Bid);
      lrClose.Dist       = 0;
      lrClose.GridPips   = GridPips;
      lrClose.s          = s;
      lrClose.lotFactor  = lotFactorAdj;
      lrClose.BaseLot    = BaseLot;
      lrClose.MaxLot     = MaxLot;
      lrClose.actualLot  = oldLots;
      lrClose.seqStr     = oldSeq;
      lrClose.CommentTag = OrderComment();
      lrClose.Magic      = MagicNumber;
      lrClose.OrderType  = OrderTypeToStr(type);
      lrClose.EntryPrice = OrderOpenPrice();
      lrClose.SL         = OrderStopLoss();
      lrClose.TP         = OrderTakeProfit();
      lrClose.ErrorCode  = errClose;
      WriteLog(lrClose);
      if(errClose != 0)
      {
         PrintFormat("HandleOCODetectionFor: failed to close %s position %d err=%d", system, posTicket, errClose);
         return;
      }

      ProcessClosedTrades(system, false);

      RefreshRates();
      double price = (type == OP_BUY) ? Ask : Bid;
      double dist = DistanceToExistingPositions(price);
      if(UseDistanceBand && dist >= 0 && (dist < MinDistancePips || dist > MaxDistancePips))
      {
         LogRecord lrSkip;
         lrSkip.Time       = TimeCurrent();
         lrSkip.Symbol     = Symbol();
         lrSkip.System     = system;
         lrSkip.Reason     = "REFILL";
         lrSkip.Spread     = PriceToPips(Ask - Bid);
         lrSkip.Dist       = dist;
         lrSkip.GridPips   = GridPips;
         lrSkip.s          = s;
         lrSkip.lotFactor  = lotFactorAdj;
         lrSkip.BaseLot    = BaseLot;
         lrSkip.MaxLot     = MaxLot;
         lrSkip.actualLot  = expectedLot;
         lrSkip.seqStr     = seqAdj;
         lrSkip.CommentTag = expectedComment;
         lrSkip.Magic      = MagicNumber;
         lrSkip.OrderType  = OrderTypeToStr(type);
         lrSkip.EntryPrice = price;
         lrSkip.SL         = 0;
         lrSkip.TP         = 0;
         lrSkip.ErrorCode  = 0;
         WriteLog(lrSkip);
         PrintFormat("HandleOCODetectionFor: distance %.1f outside band [%.1f, %.1f], order skipped",
                     dist, MinDistancePips, MaxDistancePips);
         if(system == "A")
            retryTicketA = -1;
         else
            retryTicketB = -1;
         return;
      }
      int    slippage = UseProtectedLimit ? (int)MathRound(SlippagePips * Pip() / Point) : 0;
      int newTicket = OrderSend(Symbol(), type, expectedLot, price,
                                slippage, 0, 0,
                                expectedComment, MagicNumber, 0, clrNONE);
      LogRecord lrOpen;
      lrOpen.Time       = TimeCurrent();
      lrOpen.Symbol     = Symbol();
      lrOpen.System     = system;
      lrOpen.Reason     = "REFILL";
      lrOpen.Spread     = PriceToPips(Ask - Bid);
      lrOpen.Dist       = (dist >= 0) ? dist : 0;
      lrOpen.GridPips   = GridPips;
      lrOpen.s          = s;
      lrOpen.lotFactor  = lotFactorAdj;
      lrOpen.BaseLot    = BaseLot;
      lrOpen.MaxLot     = MaxLot;
      lrOpen.actualLot  = expectedLot;
      lrOpen.seqStr     = seqAdj;
      lrOpen.CommentTag = expectedComment;
      lrOpen.Magic      = MagicNumber;
      lrOpen.OrderType  = OrderTypeToStr(type);
      lrOpen.EntryPrice = price;
      lrOpen.SL         = 0;
      lrOpen.TP         = 0;
      lrOpen.ErrorCode  = (newTicket < 0) ? GetLastError() : 0;
      WriteLog(lrOpen);
      if(newTicket < 0)
      {
         PrintFormat("HandleOCODetectionFor: failed to reopen %s position err=%d", system, lrOpen.ErrorCode);
         if(system == "A")
            retryTicketA = -1;
         else
            retryTicketB = -1;
         return;
      }
      posTicket = newTicket;
      if(!OrderSelect(posTicket, SELECT_BY_TICKET))
      {
         if(system == "A")
            retryTicketA = -1;
         else
            retryTicketB = -1;
         return;
      }
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

   RefreshRates(); // 最新の Bid/Ask を取得
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
   if(SnapCooldownBars < 0)
   {
      Print("SnapCooldownBars must be non-negative");
      return(INIT_PARAMETERS_INCORRECT);
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
   if(!InitStrategy())
      Print("InitStrategy failed, will retry on next tick");

   return(INIT_SUCCEEDED);
}

void OnTick()
{
   // Correct duplicate positions before OCO detection
   CorrectDuplicatePositions();
   // OCO detection should run once per tick after correction
   HandleOCODetection();

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

   if(posCount == 0 && !pendA && !pendB && state_A == None && state_B == None)
   {
      if(!InitStrategy())
         Print("InitStrategy failed, will retry on next tick");
      return;
   }

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
              if(!InitStrategy())
                 Print("InitStrategy failed, will retry on next tick");
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
           if(!InitStrategy())
              Print("InitStrategy failed, will retry on next tick");
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
      // RESET_ALIVE: 保存失敗時も規定の Reason に収める
      rec.Reason    = "RESET_ALIVE";
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
      // RESET_ALIVE: 保存失敗時も規定の Reason に収める
      rec.Reason    = "RESET_ALIVE";
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

