#property strict

#include <DecompositionMonteCarloMM.mqh>
#include <stderror.mqh>

#define ERR_SPREAD_EXCEEDED  10001  // Spread above MaxSpreadPips
#define ERR_DISTANCE_BAND    10002  // Distance band violation

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
input double GridPips          = 100;   // TP/SL distance (pips)
input double EpsilonPips       = 1.0;   // Tolerance width (pips)
input double MaxSpreadPips     = 2.0;   // Max spread when placing orders
input bool   UseProtectedLimit = true;  // Use slippage protection only when recovering after SL
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

enum SystemState { None=0, Alive=1, Missing=2, MissingRecovered=3 };
SystemState state_A = None;
SystemState state_B = None;

int lastSnapBar = -1; // last bar index when tick snap reset occurred

datetime lastCloseTimeA = 0; // last processed close time for system A
datetime lastCloseTimeB = 0; // last processed close time for system B
int      lastTicketsA[];     // tickets processed at lastCloseTimeA
int      lastTicketsB[];     // tickets processed at lastCloseTimeB

int retryTicketA = -1; // ticket to retry TP/SL setting for system A
int retryTicketB = -1; // ticket to retry TP/SL setting for system B
int retryTypeA   = -1; // order type to retry opening after failure for system A
int retryTypeB   = -1; // order type to retry opening after failure for system B

bool shadowRetryA = false; // flag to retry shadow order for system A
bool shadowRetryB = false; // flag to retry shadow order for system B

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
   string   ErrorInfo;
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

string ErrorDescriptionWrap(const int code)
{
   return(ErrorDescription(code));
}

void MigrateLogIfNeeded()
{
   static bool migrated = false;
   if(migrated)
      return;
   string filename = "MoveCatcher.log";
   if(FileIsExist(filename) && !FileIsExist(filename, FILE_COMMON))
   {
      string src = TerminalInfoString(TERMINAL_DATA_PATH) + "\\MQL4\\Files\\" + filename;
      string dst = TerminalInfoString(TERMINAL_COMMONDATA_PATH) + "\\Files\\" + filename;
      ResetLastError();
      if(!FileMove(src, dst, FILE_COMMON))
      {
         int err = GetLastError();
         PrintFormat("MigrateLog: FileMove err=%d %s", err, ErrorDescriptionWrap(err));
      }
   }
   migrated = true;
}

void WriteLog(const LogRecord &rec)
{
   MigrateLogIfNeeded();
   ResetLastError();
   int handle = FileOpen("MoveCatcher.log", FILE_CSV|FILE_COMMON|FILE_WRITE|FILE_READ);
   string timeStr = TimeToString(rec.Time, TIME_DATE|TIME_SECONDS);
   double distNorm = MathMax(rec.Dist, 0);
   LogRecord lr = rec;
   if(handle == INVALID_HANDLE)
   {
      int err = GetLastError();
      PrintFormat("WriteLog: FileOpen err=%d %s", err, ErrorDescriptionWrap(err));
   }
   else
   {
      FileSeek(handle, 0, SEEK_END);
      int written = (int)FileWrite(handle,
         timeStr,
         rec.Symbol,
         rec.System,
         rec.Reason,
         DoubleToString(rec.Spread,1),
         DoubleToString(distNorm,1),
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
         DoubleToString(rec.EntryPrice,_Digits),
         DoubleToString(rec.SL,_Digits),
         DoubleToString(rec.TP,_Digits),
         rec.ErrorCode,
         rec.ErrorInfo);
      if(written <= 0)
      {
         int err = GetLastError();
         string info = ErrorDescriptionWrap(err);
         PrintFormat("WriteLog: FileWrite err=%d %s", err, info);
         lr.ErrorCode = err;
         lr.ErrorInfo = info;
      }
      FileClose(handle);
   }
   PrintFormat("LOG %s,%s,%s,%s,%.1f,%.1f,%.1f,%.1f,%.2f,%.2f,%.2f,%.2f,%s,%s,%d,%s,%.*f,%.*f,%.*f,%d,%s",
               timeStr,
               rec.Symbol,
               rec.System,
               rec.Reason,
               rec.Spread,
               distNorm,
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
               _Digits, rec.EntryPrice,
               _Digits, rec.SL,
               _Digits, rec.TP,
               lr.ErrorCode,
               lr.ErrorInfo);
}

bool IsStep(const double value,const double step)
{
   double scaled = value/step;
   return(MathAbs(scaled - MathRound(scaled)) < 1e-8);
}

double Pip()
{
   return((_Digits == 3 || _Digits == 5) ? 10 * _Point : _Point);
}

double PipsToPrice(const double p)
{
   return(p * Pip());
}

double PriceToPips(const double priceDiff)
{
   return(priceDiff / Pip());
}

bool RefreshRatesChecked(const string func)
{
   ResetLastError();
   if(!RefreshRates())
   {
      int err = GetLastError();
      PrintFormat("%s: RefreshRates failed err=%d %s", func, err, ErrorDescriptionWrap(err));
      return(false);
   }
   return(true);
}

double NormalizeLot(const double lotCandidate)
{
   ResetLastError();
   double minLot  = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot  = MarketInfo(Symbol(), MODE_MAXLOT);
   double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);
   int marketErr  = GetLastError();

   if(minLot <= 0 || maxLot <= 0)
   {
      PrintFormat("NormalizeLot: invalid lot range minLot=%.2f maxLot=%.2f err=%d %s",
                  minLot, maxLot, marketErr, ErrorDescriptionWrap(marketErr));
      if(minLot <= 0)
         minLot = 0.01;
      if(maxLot <= 0)
         maxLot = 100.0;
   }

   if(minLot > maxLot)
   {
      PrintFormat("NormalizeLot: minLot %.2f greater than maxLot %.2f, adjusting maxLot", minLot, maxLot);
      maxLot = minLot;
   }

   double lot = lotCandidate;
   int    lotDigits = 0;
   if(lotStep > 0)
   {
      lot = MathRound(lot / lotStep) * lotStep;
      lotDigits = (int)MathRound(-MathLog(lotStep) / MathLog(10));
      lot = NormalizeDouble(lot, lotDigits);
   }

   if(lot < minLot)
      lot = minLot;
   if(lot > maxLot)
      lot = maxLot;

   if(lotStep > 0)
      return(NormalizeDouble(lot, lotDigits));
   return(lot);
}

double ClipToUserMax(const double lot)
{
   double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);
   if(lotStep <= 0)
   {
      double result = lot;
      if(result > MaxLot)
         result = MaxLot;
      return(result);
   }

   int    lotDigits = (int)MathRound(-MathLog(lotStep) / MathLog(10));
   double maxLotAdj = MathFloor(MaxLot / lotStep) * lotStep;
   maxLotAdj = NormalizeDouble(maxLotAdj, lotDigits);

   double result = lot;
   if(result > maxLotAdj)
      result = maxLotAdj;

   return(NormalizeDouble(result, lotDigits));
}

void AddTicket(int &arr[],const int ticket)
{
   int idx=ArraySize(arr);
   ArrayResize(arr,idx+1);
   arr[idx]=ticket;
}

bool ContainsTicket(const int &arr[],const int ticket)
{
   for(int i=0;i<ArraySize(arr);i++)
   {
      if(arr[i]==ticket)
         return(true);
   }
   return(false);
}

// チケットごとの lotFactor を保持するための配列
int    lotFactorTickets[];
double lotFactorValues[];

// 注文発行時の lotFactor を保存
void StoreLotFactor(const int ticket,const double lotFactor)
{
   int idx = ArraySize(lotFactorTickets);
   ArrayResize(lotFactorTickets, idx + 1);
   ArrayResize(lotFactorValues, idx + 1);
   lotFactorTickets[idx] = ticket;
   lotFactorValues[idx] = lotFactor;
}

// コメントまたは保存情報から lotFactor を取得
bool ExtractLotFactor(const int ticket,const string comment,double &lotFactor)
{
   int pos = StringFind(comment, "|LF=");
   if(pos >= 0)
   {
      lotFactor = StringToDouble(StringSubstr(comment, pos + 4));
      return(true);
   }
   for(int i = ArraySize(lotFactorTickets)-1; i >= 0; i--)
   {
      if(lotFactorTickets[i] == ticket)
      {
         lotFactor = lotFactorValues[i];
         int last = ArraySize(lotFactorTickets) - 1;
         lotFactorTickets[i] = lotFactorTickets[last];
         lotFactorValues[i] = lotFactorValues[last];
         ArrayResize(lotFactorTickets, last);
         ArrayResize(lotFactorValues, last);
         return(true);
      }
   }
   return(false);
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

      string prefix=StringFormat("MoveCatcher_%s_%d_%s_",Symbol(),MagicNumber,system);

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

   string filename=StringFormat("MoveCatcher_state_%s_%d_%s.dat",Symbol(),MagicNumber,system);
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
   string prefix=StringFormat("MoveCatcher_%s_%d_%s_",Symbol(),MagicNumber,system);
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

   // Legacy global variables and file without symbol and magic number
   string legacyPrefix="MoveCatcher_"+system+"_";
   string legacyFile="MoveCatcher_state_"+system+".dat";
   if(GlobalVariableCheck(legacyPrefix+"seq_size") && GlobalVariableCheck(legacyPrefix+"stock") && GlobalVariableCheck(legacyPrefix+"streak"))
   {
      int n=(int)MathRound(GlobalVariableGet(legacyPrefix+"seq_size"));
      int stock=(int)MathRound(GlobalVariableGet(legacyPrefix+"stock"));
      int streak=(int)MathRound(GlobalVariableGet(legacyPrefix+"streak"));
      string seqStr=""; bool ok=true;
      for(int i=0;i<n;i++)
      {
         string name=legacyPrefix+"seq_"+IntegerToString(i);
         if(!GlobalVariableCheck(name)){ok=false; break;}
         int v=(int)MathRound(GlobalVariableGet(name));
         if(i) seqStr+=","; seqStr+=IntegerToString(v);
      }
      if(ok)
      {
         string data=IntegerToString(stock)+"|"+IntegerToString(streak)+"|"+seqStr;
         if(state.Deserialize(data))
         {
            int dummyErr; SaveDMCState(system,state,dummyErr);
            GlobalVariableDel(legacyPrefix+"stock");
            GlobalVariableDel(legacyPrefix+"streak");
            GlobalVariableDel(legacyPrefix+"seq_size");
            for(int j=0;j<n;j++) GlobalVariableDel(legacyPrefix+"seq_"+IntegerToString(j));
            if(FileIsExist(legacyFile,FILE_COMMON)) FileDelete(legacyFile,FILE_COMMON);
            return(true);
         }
      }
   }

   string filename=StringFormat("MoveCatcher_state_%s_%d_%s.dat",Symbol(),MagicNumber,system);
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

   if(FileIsExist(legacyFile,FILE_COMMON))
   {
      int handle=FileOpen(legacyFile,FILE_COMMON|FILE_READ|FILE_TXT);
      if(handle!=INVALID_HANDLE)
      {
         string data=FileReadString(handle);
         FileClose(handle);
         if(state.Deserialize(data))
         {
            int dummyErr; SaveDMCState(system,state,dummyErr);
            FileDelete(legacyFile,FILE_COMMON);
            return(true);
         }
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
double DistanceToExistingPositions(const double price,const int excludeTicket=-1)
{
   double minDist = DBL_MAX;
   for(int i = OrdersTotal()-1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderMagicNumber() != MagicNumber || OrderSymbol() != Symbol())
         continue;
      if(OrderTicket() == excludeTicket)
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
//+------------------------------------------------------------------+
bool CanPlaceOrder(double &price,const bool isBuy,string &errorInfo,
                   bool checkSpread=true,int excludeTicket=-1,bool checkDistance=true)
{
   if(!RefreshRatesChecked(__FUNCTION__))
   {
      errorInfo = "RefreshRates failed";
      return(false);
   }

   double stopLevel   = MarketInfo(Symbol(), MODE_STOPLEVEL) * _Point;
   double freezeLevel = MarketInfo(Symbol(), MODE_FREEZELEVEL) * _Point;

   // 注文方向に応じた基準価格を取得
   double ref  = isBuy ? Ask : Bid;
   price       = NormalizeDouble(price, _Digits);
   double dist = price - ref;
   double absDist = MathAbs(dist);

   // 方向チェック: BuyLimit は Ask 未満 / SellLimit は Bid 超過
   if((isBuy && dist >= 0) || (!isBuy && dist <= 0))
   {
      PrintFormat("CanPlaceOrder: price %.*f on wrong side of %s %.*f",
                  _Digits, price, isBuy ? "Ask" : "Bid", _Digits, ref);
      errorInfo = "Wrong direction";
      return(false);
   }

   if(absDist < freezeLevel)
   {
      PrintFormat("CanPlaceOrder: price %.*f within freeze level %.1f pips, retry next tick",
                  _Digits, price, PriceToPips(freezeLevel));
      errorInfo = "FreezeLevel violation";
      return(false);
   }

   if(absDist < stopLevel)
   {
      double oldPrice = price;
      price = isBuy ? ref - stopLevel : ref + stopLevel;
      price = NormalizeDouble(price, _Digits);
      PrintFormat("CanPlaceOrder: price adjusted from %.*f to %.*f due to stop level %.1f pips",
                  _Digits, oldPrice, _Digits, price, PriceToPips(stopLevel));

      // StopLevel 補正後に距離を再計算し、方向と FreezeLevel を再チェック
      dist     = price - ref;
      absDist  = MathAbs(dist);
      if((isBuy && dist >= 0) || (!isBuy && dist <= 0))
      {
         PrintFormat("CanPlaceOrder: adjusted price %.*f on wrong side of %s %.*f",
                     _Digits, price, isBuy ? "Ask" : "Bid", _Digits, ref);
         errorInfo = "Wrong direction";
         return(false);
      }
      if(absDist < freezeLevel)
      {
         PrintFormat("CanPlaceOrder: price %.*f within freeze level %.1f pips after stop adjustment, retry next tick",
                     _Digits, price, PriceToPips(freezeLevel));
         errorInfo = "FreezeLevel violation";
         return(false);
      }
   }

   double spread = PriceToPips(MathAbs(Ask - Bid));
   if(checkSpread && MaxSpreadPips > 0 && spread > MaxSpreadPips)
   {
      PrintFormat("Spread %.1f exceeds MaxSpreadPips %.1f", spread, MaxSpreadPips);
      errorInfo = "SpreadExceeded";
      return(false);
   }

   if(checkDistance && UseDistanceBand)
   {
      double bandDist = DistanceToExistingPositions(price, excludeTicket);
      if(bandDist >= 0 && (bandDist < MinDistancePips || bandDist > MaxDistancePips))
      {
         PrintFormat("Distance %.1f outside band [%.1f, %.1f]", bandDist, MinDistancePips, MaxDistancePips);
         errorInfo = "DistanceBandViolation";
         return(false);
      }
   }

   errorInfo = "";
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
   string seqCore;
   const int seqMaxLen = 15;
   if(!state.Seq(seqCore, seqMaxLen))
   {
      PrintFormat("Seq length overflow for system %s", system);
      seq="";
      lotFactor=0.0;
      return(0.0);
   }
   seq                = "(" + seqCore + ")";
   double lotCandidate = BaseLot * lotFactor;
   if(lotFactor <= 0)
   {
      PrintFormat("CalcLot: lotFactor=%f <= 0 for system %s", lotFactor, system);
      state.Init();
      int err = 0;
      bool ok = SaveDMCState(system, *state, err);
      if(!ok && err != 0)
         PrintFormat("SaveDMCState(%s) err=%d %s", system, err, ErrorDescriptionWrap(err));

      LogRecord lr;
      lr.Time       = TimeCurrent();
      lr.Symbol     = Symbol();
      lr.System     = system;
      lr.Reason     = "LOT_RESET";
      lr.Spread     = PriceToPips(MathAbs(Ask - Bid));
      lr.Dist       = 0;
      lr.GridPips   = GridPips;
      lr.s          = s;
      lr.lotFactor  = lotFactor;
      lr.BaseLot    = BaseLot;
      lr.MaxLot     = MaxLot;
      lr.actualLot  = 0.0;
      lr.seqStr     = seq;
      lr.CommentTag = MakeComment(system, seq);
      lr.Magic      = MagicNumber;
      lr.OrderType  = "";
      lr.EntryPrice = 0;
      lr.SL         = 0;
      lr.TP         = 0;
      lr.ErrorCode  = err;
      if(err == 0)
         lr.ErrorInfo  = "";
      else
         lr.ErrorInfo  = ErrorDescriptionWrap(err);
      WriteLog(lr);

      return(0.0);
   }

   if(lotCandidate > MaxLot)
   {
      state.Init();
      lotFactor    = state.NextLot();
      int err = 0;
      bool ok = SaveDMCState(system, *state, err);
      if(!ok && err != 0)
         PrintFormat("SaveDMCState(%s) err=%d %s", system, err, ErrorDescriptionWrap(err));

      if(!state.Seq(seqCore, seqMaxLen))
      {
         PrintFormat("Seq length overflow for system %s", system);
         seq="";
         lotFactor=0.0;
         return(0.0);
      }
      seq          = "(" + seqCore + ")";
      if(lotFactor <= 0)
      {
         LogRecord lr;
         lr.Time       = TimeCurrent();
         lr.Symbol     = Symbol();
         lr.System     = system;
         lr.Reason     = "LOT_RESET";
         lr.Spread     = PriceToPips(MathAbs(Ask - Bid));
         lr.Dist       = 0;
         lr.GridPips   = GridPips;
         lr.s          = s;
         lr.lotFactor  = lotFactor;
         lr.BaseLot    = BaseLot;
         lr.MaxLot     = MaxLot;
         lr.actualLot  = 0.0;
         lr.seqStr     = seq;
         lr.CommentTag = MakeComment(system, seq);
         lr.Magic      = MagicNumber;
         lr.OrderType  = "";
         lr.EntryPrice = 0;
         lr.SL         = 0;
         lr.TP         = 0;
         lr.ErrorCode  = err;
         if(err == 0)
            lr.ErrorInfo  = "";
         else
            lr.ErrorInfo  = ErrorDescriptionWrap(err);
         WriteLog(lr);
         return(0.0);
      }
      lotCandidate = BaseLot * lotFactor;
      double lotActual = NormalizeLot(lotCandidate);
      lotActual = ClipToUserMax(lotActual);

      LogRecord lr;
      lr.Time       = TimeCurrent();
      lr.Symbol     = Symbol();
      lr.System     = system;
      lr.Reason     = "LOT_RESET";
      lr.Spread     = PriceToPips(MathAbs(Ask - Bid));
      lr.Dist       = 0;
      lr.GridPips   = GridPips;
      lr.s          = s;
      lr.lotFactor  = lotFactor;
      lr.BaseLot    = BaseLot;
      lr.MaxLot     = MaxLot;
      lr.actualLot  = lotActual;
      lr.seqStr     = seq;
      lr.CommentTag = MakeComment(system, seq);
      lr.Magic      = MagicNumber;
      lr.OrderType  = "";
      lr.EntryPrice = 0;
      lr.SL         = 0;
      lr.TP         = 0;
      lr.ErrorCode  = err;
      if(err == 0)
         lr.ErrorInfo  = "";
      else
         lr.ErrorInfo  = ErrorDescriptionWrap(err);
      WriteLog(lr);

      return(lotActual);
   }

   double lotActual = NormalizeLot(lotCandidate);
   lotActual = ClipToUserMax(lotActual);
   return(lotActual);
}

//+------------------------------------------------------------------+
//| Make comment string from system and sequence                     |
//+------------------------------------------------------------------+
string MakeComment(const string system,const string seq)
{
   const int MAX_COMMENT_LENGTH = 31;
   string comment = StringFormat("MoveCatcher_%s_%s", system, seq);
   int len = StringLen(comment);
   if(len > MAX_COMMENT_LENGTH)
   {
      string prefix = StringFormat("MoveCatcher_%s_", system);
      int tailLen = MAX_COMMENT_LENGTH - StringLen(prefix) - 3;
      if(tailLen < 0) tailLen = 0;
      int seqLen = StringLen(seq);
      int tailStart = seqLen - tailLen;
      if(tailStart < 0) tailStart = 0;
      string tail = StringSubstr(seq, tailStart);
      string truncated = prefix + "..." + tail;
      PrintFormat("MakeComment: comment '%s' length %d exceeds %d, truncated to '%s'", comment, len, MAX_COMMENT_LENGTH, truncated);
      comment = truncated;
   }
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
   if(prev == Alive || prev == MissingRecovered) return(Missing);
   return(prev == Missing ? Missing : None);
}

//+------------------------------------------------------------------+
//| Initialize last close times for both systems                      |
//+------------------------------------------------------------------+
void InitCloseTimes()
{
   lastCloseTimeA = 0;
   lastCloseTimeB = 0;
   ArrayResize(lastTicketsA,0);
   ArrayResize(lastTicketsB,0);
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
      if(sys == "A")
      {
         if(ct > lastCloseTimeA)
         {
            lastCloseTimeA = ct;
            ArrayResize(lastTicketsA,0);
            AddTicket(lastTicketsA,OrderTicket());
         }
         else if(ct == lastCloseTimeA)
            AddTicket(lastTicketsA,OrderTicket());
      }
      else if(sys == "B")
      {
         if(ct > lastCloseTimeB)
         {
            lastCloseTimeB = ct;
            ArrayResize(lastTicketsB,0);
            AddTicket(lastTicketsB,OrderTicket());
         }
         else if(ct == lastCloseTimeB)
            AddTicket(lastTicketsB,OrderTicket());
      }
   }
}

//+------------------------------------------------------------------+
//| Process newly closed trades for specified system                  |
//| updateDMC=false で DMCMM 状態更新を抑制しログのみ残す           |
//| reason が指定されていれば TP/SL 判定の代わりにその値を使用      |
//+------------------------------------------------------------------+
void ProcessClosedTrades(const string system,const bool updateDMC,const string reason="")
{
   datetime lastTime = (system == "A") ? lastCloseTimeA : lastCloseTimeB;
   int tickets[];
   datetime times[];
   int newTickets[];
   if(system == "A")
      ArrayCopy(newTickets,lastTicketsA);
   else
      ArrayCopy(newTickets,lastTicketsB);
   datetime newLastTime = lastTime;
   bool hasNew = false;
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
      if(ct < lastTime)
         continue;
      if(ct == lastTime)
      {
         if(system == "A")
         {
            if(ContainsTicket(lastTicketsA,OrderTicket()))
               continue;
         }
         else
         {
            if(ContainsTicket(lastTicketsB,OrderTicket()))
               continue;
         }
      }
      int idx = ArraySize(tickets);
      ArrayResize(tickets, idx + 1);
      ArrayResize(times, idx + 1);
      tickets[idx] = OrderTicket();
      times[idx]   = ct;
      if(ct > newLastTime)
      {
         newLastTime = ct;
         ArrayResize(newTickets,0);
         AddTicket(newTickets,OrderTicket());
         hasNew = true;
      }
      else if(ct == newLastTime)
      {
         if(!ContainsTicket(newTickets,OrderTicket()))
         {
            AddTicket(newTickets,OrderTicket());
            hasNew = true;
         }
      }
   }
   for(int i = ArraySize(tickets)-1; i >= 0; i--)
   {
      if(!OrderSelect(tickets[i], SELECT_BY_TICKET, MODE_HISTORY))
         continue;

      // 現在のスプレッドを取得（履歴からは取得不可のため近似値）
      if(!RefreshRatesChecked(__FUNCTION__))
      {
         int tkWarn = OrderTicket();
         PrintFormat("ProcessClosedTrades: RefreshRatesChecked failed, skip ticket %d", tkWarn);
         continue;
      }
      double spreadNow = PriceToPips(MathAbs(Ask - Bid));
      int type  = OrderType();

      string sysTmp, seq;
      if(!ParseComment(OrderComment(), sysTmp, seq))
         seq = "";
      string rsn = reason;
      if(rsn == "")
      {
         double closePrice = OrderClosePrice();
        double tol        = Pip() * 0.5;
         bool isTP = (MathAbs(closePrice - OrderTakeProfit()) <= tol);
         bool isSL = (MathAbs(closePrice - OrderStopLoss())  <= tol);
         bool hasTP = (OrderTakeProfit() > 0);
         bool hasSL = (OrderStopLoss()  > 0);
         if((hasTP && isTP) || (hasSL && isSL))
            rsn = (hasTP && isTP) ? "TP" : "SL";
         else
         {
            string cmt = StringToUpper(OrderComment());
            if(StringFind(cmt, "TP") >= 0)
               rsn = "TP";
            else if(StringFind(cmt, "SL") >= 0)
               rsn = "SL";
            else
            {
               double openPrice = OrderOpenPrice();
               if(OrderType() == OP_BUY)
                  rsn = (closePrice >= openPrice) ? "TP" : "SL";
               else
                  rsn = (closePrice <= openPrice) ? "TP" : "SL";
            }
         }
      }

      bool win = (rsn == "TP");
      if(system == "A")
      {
         if(updateDMC)
            stateA.OnTrade(win);
      }
      else
      {
         if(updateDMC)
            stateB.OnTrade(win);
      }
      double dist = DistanceToExistingPositions(OrderOpenPrice(), OrderTicket());
      dist = MathMax(dist, 0);
      LogRecord lr;
      lr.Time       = times[i];
      lr.Symbol     = Symbol();
      lr.System     = system;
      lr.Reason     = rsn;
      lr.Spread     = spreadNow;
      lr.Dist       = dist;
      lr.GridPips   = GridPips;
      lr.s          = s;
      double lfTmp;
      if(!ExtractLotFactor(OrderTicket(), OrderComment(), lfTmp))
         lfTmp = OrderLots() / BaseLot;
      lr.lotFactor  = lfTmp;
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
      lr.ErrorInfo  = "";
      if(updateDMC)
      {
         int err = 0;
         bool saved = SaveDMCState(system, (system == "A") ? stateA : stateB, err);
         if(!saved)
         {
            string info = ErrorDescriptionWrap(err);
            if(err != 0)
               PrintFormat("SaveDMCState(%s) err=%d %s", system, err, info);
            lr.ErrorCode = err;
            lr.ErrorInfo = info;
         }
      }
      WriteLog(lr);
   }
   if(hasNew)
   {
      if(system == "A")
      {
         lastCloseTimeA = newLastTime;
         ArrayCopy(lastTicketsA,newTickets);
      }
      else
      {
         lastCloseTimeB = newLastTime;
         ArrayCopy(lastTicketsB,newTickets);
      }
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
   double tol = Pip() * 0.5;
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
   if(!RefreshRatesChecked(__FUNCTION__))
      return;
   if(!OrderSelect(ticket, SELECT_BY_TICKET))
      return;
   double entry = OrderOpenPrice();
   bool   isBuy = (OrderType() == OP_BUY);
   double desiredSL = isBuy ? entry - PipsToPrice(GridPips)
                            : entry + PipsToPrice(GridPips);
   double desiredTP = isBuy ? entry + PipsToPrice(GridPips)
                            : entry - PipsToPrice(GridPips);

   double stopLevel   = MarketInfo(Symbol(), MODE_STOPLEVEL) * _Point;
   double freezeLevel = MarketInfo(Symbol(), MODE_FREEZELEVEL) * _Point;
   double minDist     = MathMax(stopLevel, freezeLevel);

   desiredSL = NormalizeDouble(desiredSL, _Digits);
   desiredTP = NormalizeDouble(desiredTP, _Digits);
   double tol = Pip() * 0.5;
   bool needModify = (OrderStopLoss() == 0 || OrderTakeProfit() == 0 ||
                      MathAbs(OrderStopLoss() - desiredSL) > tol ||
                      MathAbs(OrderTakeProfit() - desiredTP) > tol);
   if(!needModify)
      return;

   bool violates = false;
   if(isBuy)
      violates = (Bid - desiredSL < minDist) || (desiredTP - Bid < minDist);
   else
      violates = (desiredSL - Ask < minDist) || (Ask - desiredTP < minDist);

   string sys, seq;
   ParseComment(OrderComment(), sys, seq);
   if(violates)
   {
      LogRecord lrv;
      lrv.Time       = TimeCurrent();
      lrv.Symbol     = Symbol();
      lrv.System     = sys;
      lrv.Reason     = "REFILL";
      lrv.Spread     = PriceToPips(MathAbs(Ask - Bid));
      lrv.Dist       = 0;
      lrv.GridPips   = GridPips;
      lrv.s          = s;
      lrv.lotFactor  = 0;
      lrv.BaseLot    = BaseLot;
      lrv.MaxLot     = MaxLot;
      lrv.actualLot  = OrderLots();
      lrv.seqStr     = seq;
      lrv.CommentTag = OrderComment();
      lrv.Magic      = MagicNumber;
      lrv.OrderType  = OrderTypeToStr(OrderType());
      lrv.EntryPrice = entry;
      lrv.SL         = desiredSL;
      lrv.TP         = desiredTP;
      lrv.ErrorCode  = ERR_INVALID_STOPS;
      lrv.ErrorInfo  = "Stop/Freeze level violation";
      WriteLog(lrv);
      if(sys == "A")
         retryTicketA = ticket;
      else if(sys == "B")
         retryTicketB = ticket;
      PrintFormat("EnsureTPSL: TP/SL for ticket %d within stop/freeze level, retry next tick", ticket);
      return;
   }

   ResetLastError();
   if(!OrderModify(ticket, entry, desiredSL, desiredTP, 0, clrNONE))
   {
      int err = GetLastError();
      if(err == ERR_INVALID_STOPS)
         PrintFormat("EnsureTPSL: TP/SL for ticket %d within stop/freeze level, retry next tick err=%d", ticket, err);
      else
         PrintFormat("EnsureTPSL: failed to set TP/SL for ticket %d err=%d", ticket, err);

      LogRecord lr;
      lr.Time       = TimeCurrent();
      lr.Symbol     = Symbol();
      lr.System     = sys;
      lr.Reason     = "REFILL";
      lr.Spread     = PriceToPips(MathAbs(Ask - Bid));
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
      if(sys == "A")
         retryTicketA = ticket;
      else if(sys == "B")
         retryTicketB = ticket;
   }
   else
   {
      if(OrderSelect(ticket, SELECT_BY_TICKET))
      {
         LogRecord lr;
         lr.Time       = TimeCurrent();
         lr.Symbol     = Symbol();
         lr.System     = sys;
         lr.Reason     = "REFILL";
         lr.Spread     = PriceToPips(MathAbs(Ask - Bid));
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
         lr.SL         = OrderStopLoss();
         lr.TP         = OrderTakeProfit();
         lr.ErrorCode  = 0;
         WriteLog(lr);
      }
      if(sys == "A")
         retryTicketA = -1;
      else if(sys == "B")
         retryTicketB = -1;
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
   bool hasPend = FindShadowPending(system, entry, isBuy, pendTicket, pendLot, pendComment);
   bool needRetry = (system == "A") ? shadowRetryA : shadowRetryB;
   if(hasPend && !needRetry)
   {
      double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);
      double lotTol  = (lotStep > 0) ? lotStep * 0.5 : 1e-8;
      if(MathAbs(pendLot - lot) <= lotTol && pendComment == comment)
         return; // already exists with expected lot/comment
   }

   double price = isBuy ? entry + PipsToPrice(GridPips)
                        : entry - PipsToPrice(GridPips);
   price = NormalizeDouble(price, _Digits);
   int type = isBuy ? OP_SELLLIMIT : OP_BUYLIMIT;
   if(!RefreshRatesChecked(__FUNCTION__))
      return;

   string errcp = "";
   bool   canPlace = CanPlaceOrder(price, (type == OP_BUYLIMIT), errcp, false, ticket, false);
   double distBand = MathMax(DistanceToExistingPositions(price, ticket), 0);
   if(!canPlace)
   {
      LogRecord lre;
      lre.Time       = TimeCurrent();
      lre.Symbol     = Symbol();
      lre.System     = system;
      lre.Reason     = "REFILL";
      lre.Spread     = PriceToPips(MathAbs(Ask - Bid));
      lre.Dist       = distBand;
      lre.GridPips   = GridPips;
      lre.s          = s;
      lre.lotFactor  = lotFactor;
      lre.BaseLot    = BaseLot;
      lre.MaxLot     = MaxLot;
      lre.actualLot  = lot;
      lre.seqStr     = seq;
      lre.CommentTag = comment;
      lre.Magic      = MagicNumber;
      lre.OrderType  = OrderTypeToStr(type);
      lre.EntryPrice = price;
      lre.SL         = 0;
      lre.TP         = 0;
      int errCode = 0;
      string errMsg = errcp;
      if(errcp == "FreezeLevel violation")
         errCode = ERR_INVALID_STOPS;
      else if(errcp == "Wrong direction")
         errCode = ERR_INVALID_PRICE;
      lre.ErrorCode  = errCode;
      lre.ErrorInfo  = hasPend ? errMsg + " (existing order kept)" : errMsg;
      WriteLog(lre);
      if(hasPend)
         PrintFormat("EnsureShadowOrder: %s - keeping existing shadow order for %s", errMsg, system);
      else
         PrintFormat("EnsureShadowOrder: %s - will retry for %s", errMsg, system);

      if(system == "A")
         shadowRetryA = true;
      else
         shadowRetryB = true;
      return;
   }

   if(hasPend)
   {
      int pendType  = isBuy ? OP_SELLLIMIT : OP_BUYLIMIT;
      double pendPrice = isBuy ? entry + PipsToPrice(GridPips)
                               : entry - PipsToPrice(GridPips);
      if(OrderSelect(pendTicket, SELECT_BY_TICKET))
      {
         pendType  = OrderType();
         pendPrice = OrderOpenPrice();
      }
      double distPend = MathMax(DistanceToExistingPositions(pendPrice, ticket), 0);
      int err = 0;
      ResetLastError();
      bool ok = OrderDelete(pendTicket);
      if(!ok)
         err = GetLastError();

      LogRecord lru;
      lru.Time       = TimeCurrent();
      lru.Symbol     = Symbol();
      lru.System     = system;
      // REFILL: 影指値の更新
      lru.Reason     = "REFILL";
      lru.Spread     = PriceToPips(MathAbs(Ask - Bid));
      lru.Dist       = distPend;
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
         if(system == "A")
            shadowRetryA = true;
         else
            shadowRetryB = true;
         return;
      }
      PrintFormat("EnsureShadowOrder: replaced shadow order for %s", system);
   }

   price = NormalizeDouble(price, _Digits);
   if(!RefreshRatesChecked(__FUNCTION__))
      return;
   ResetLastError();
   int tk = OrderSend(Symbol(), type, lot, price, 0, 0, 0, comment, MagicNumber, 0, clrNONE);
   if(tk >= 0)
      StoreLotFactor(tk, lotFactor);
   LogRecord lr;
   lr.Time       = TimeCurrent();
   lr.Symbol     = Symbol();
   lr.System     = system;
   // REFILL: 影指値（TP反転用の指値）を設置
   lr.Reason     = "REFILL";
   lr.Spread     = PriceToPips(MathAbs(Ask - Bid));
   lr.Dist       = distBand;
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
   {
      PrintFormat("EnsureShadowOrder: failed to place shadow order for %s err=%d", system, lr.ErrorCode);
      if(system == "A")
         shadowRetryA = true;
      else
         shadowRetryB = true;
   }
   else
   {
      if(system == "A")
         shadowRetryA = false;
      else
         shadowRetryB = false;
   }
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
      if(!RefreshRatesChecked(__FUNCTION__))
      {
         int tkWarn = OrderTicket();
         PrintFormat("DeletePendings: RefreshRatesChecked failed, skip ticket %d", tkWarn);
         continue;
      }
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
      ResetLastError();
      bool ok = OrderDelete(tk);
      if(!ok)
         err = GetLastError();
      LogRecord lr;
      lr.Time       = TimeCurrent();
      lr.Symbol     = Symbol();
      lr.System     = system;
      lr.Reason     = reason;
      lr.Spread     = PriceToPips(MathAbs(Ask - Bid));
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
//| Re-enter position after SL. UseProtectedLimit controls slippage     |
//| only here; when false, slippage=0.                                  |
//+------------------------------------------------------------------+
void RecoverAfterSL(const string system)
{
   ProcessClosedTrades(system, true);
   if(!RefreshRatesChecked(__FUNCTION__))
      return;
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
   double reSlippagePips = SlippagePips;
   int    slippage = UseProtectedLimit
                     ? (int)MathRound(reSlippagePips * Pip() / _Point)
                     : 0; // UseProtectedLimit=false では slippage=0
   string flagInfo = StringFormat("UseProtectedLimit=%s slippage=%d",
                                  UseProtectedLimit ? "true" : "false", slippage);
   if(!RefreshRatesChecked(__FUNCTION__))
      return;
   double price    = isBuy ? Ask : Bid;
   price           = NormalizeDouble(price, _Digits);
   double sl       = NormalizeDouble(isBuy ? price - PipsToPrice(GridPips) : price + PipsToPrice(GridPips), _Digits);
   double tp       = NormalizeDouble(isBuy ? price + PipsToPrice(GridPips) : price - PipsToPrice(GridPips), _Digits);
   double stopLevel   = MarketInfo(Symbol(), MODE_STOPLEVEL) * _Point;
   double freezeLevel = MarketInfo(Symbol(), MODE_FREEZELEVEL) * _Point;
   double minLevel    = MathMax(stopLevel, freezeLevel);

   bool violateSend = false;
   if(MathAbs(price - sl) < minLevel)
   {
      sl = 0;
      violateSend = true;
   }
   if(MathAbs(tp - price) < minLevel)
   {
      tp = 0;
      violateSend = true;
   }
   if(violateSend)
      PrintFormat("RecoverAfterSL[%s]: initial TP/SL within stop/freeze level, placing without TP/SL for %s", flagInfo, system);

   string comment  = MakeComment(system, seq);
   double spread   = PriceToPips(MathAbs(Ask - Bid));
   double dist     = DistanceToExistingPositions(price);
   // SL復帰時はSpreadおよび距離帯のチェックを行わない
   int type        = isBuy ? OP_BUY : OP_SELL;
   price           = NormalizeDouble(price, _Digits);
   ResetLastError();
   int ticket      = OrderSend(Symbol(), type, lot, price,
                               slippage, sl, tp, comment, MagicNumber, 0, clrNONE);
   if(ticket >= 0)
      StoreLotFactor(ticket, lotFactor);
   string errInfo  = flagInfo;
   if(violateSend)
      errInfo = flagInfo + " TP/SL pending";
   LogRecord lr;
   lr.Time       = TimeCurrent();
   lr.Symbol     = Symbol();
   lr.System     = system;
   lr.Reason     = "SL";
   lr.ErrorInfo  = errInfo;
   lr.Spread     = spread;
   lr.Dist       = MathMax(dist, 0);
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
      PrintFormat("RecoverAfterSL[%s]: failed to reopen %s err=%d", flagInfo, system, lr.ErrorCode);
      return;
   }

   if(!OrderSelect(ticket, SELECT_BY_TICKET))
   {
      lr.ErrorCode = GetLastError();
      WriteLog(lr);
      PrintFormat("RecoverAfterSL[%s]: failed to select reopened order for %s err=%d", flagInfo, system, lr.ErrorCode);
      return;
   }
   if(!RefreshRatesChecked(__FUNCTION__)) // Bid と Ask を最新化
      return;
   double entry = OrderOpenPrice();
   double desiredSL = isBuy ? entry - PipsToPrice(GridPips) : entry + PipsToPrice(GridPips);
   double desiredTP = isBuy ? entry + PipsToPrice(GridPips) : entry - PipsToPrice(GridPips);
   stopLevel   = MarketInfo(Symbol(), MODE_STOPLEVEL) * _Point;
   freezeLevel = MarketInfo(Symbol(), MODE_FREEZELEVEL) * _Point;
   minLevel    = MathMax(stopLevel, freezeLevel);
   desiredSL = NormalizeDouble(desiredSL, _Digits);
   desiredTP = NormalizeDouble(desiredTP, _Digits);
   double tol = Pip() * 0.5;
   bool needModify = (OrderStopLoss() == 0 || OrderTakeProfit() == 0 ||
                      MathAbs(OrderStopLoss() - desiredSL) > tol ||
                      MathAbs(OrderTakeProfit() - desiredTP) > tol);

   lr.EntryPrice = entry;
   lr.SL         = desiredSL;
   lr.TP         = desiredTP;
   if(!needModify)
   {
      lr.ErrorCode = 0;
      WriteLog(lr);
      if(system == "A")
         retryTicketA = -1;
      else
         retryTicketB = -1;
      EnsureShadowOrder(ticket, system);
      if(system == "A")
         state_A = Alive;
      else if(system == "B")
         state_B = Alive;
      return;
   }

   bool violates = false;
   if(isBuy)
      violates = (Bid - desiredSL < minLevel) || (desiredTP - Bid < minLevel);
   else
      violates = (desiredSL - Ask < minLevel) || (Ask - desiredTP < minLevel);

   if(violates)
   {
      lr.ErrorCode = ERR_INVALID_STOPS;
      lr.ErrorInfo = flagInfo + " Stop/Freeze level violation";
      WriteLog(lr);
      PrintFormat("RecoverAfterSL[%s]: TP/SL for %s ticket %d within stop/freeze level, retry next tick", flagInfo, system, ticket);
      if(system == "A")
         retryTicketA = ticket;
      else
         retryTicketB = ticket;
   }
   else
   {
      int err = 0;
      ResetLastError();
      if(!OrderModify(ticket, entry, desiredSL, desiredTP, 0, clrNONE))
      {
         err = GetLastError();
         lr.ErrorCode = err;
         lr.ErrorInfo = flagInfo;
         WriteLog(lr);
         PrintFormat("RecoverAfterSL[%s]: failed to adjust TP/SL for %s ticket %d err=%d", flagInfo, system, ticket, err);
         if(system == "A")
            retryTicketA = ticket;
         else
            retryTicketB = ticket;
      }
      else
      {
         lr.ErrorCode = 0;
         lr.ErrorInfo = flagInfo;
         lr.SL        = OrderStopLoss();
         lr.TP        = OrderTakeProfit();
         WriteLog(lr);
         if(system == "A")
            retryTicketA = -1;
         else
            retryTicketB = -1;
      }
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
   if(!RefreshRatesChecked(__FUNCTION__))
   {
      Print("CloseAllOrders: RefreshRatesChecked failed at start");
      return;
   }
   int slippage = (int)MathRound(SlippagePips * Pip() / _Point);
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
         if(!RefreshRatesChecked(__FUNCTION__))
         {
            PrintFormat("CloseAllOrders: RefreshRatesChecked failed, skip ticket %d", ticket);
            continue;
         }
         double spreadClose = PriceToPips(MathAbs(Ask - Bid));
         double price      = (type == OP_BUY) ? Bid : Ask;
         price = NormalizeDouble(price, _Digits);
         double actualLot  = OrderLots();
         string comment    = OrderComment();
         double entryPrice = OrderOpenPrice();
         double slVal      = OrderStopLoss();
         double tpVal      = OrderTakeProfit();
         string sysTmp, seqTmp;
         ParseComment(comment, sysTmp, seqTmp);
         int err = 0;
         ResetLastError();
         bool ok = OrderClose(ticket, actualLot, price, slippage, clrNONE);
         if(!ok)
            err = GetLastError();
         LogRecord lr;
         lr.Time       = TimeCurrent();
         lr.Symbol     = Symbol();
         lr.System     = sysTmp;
         lr.Reason     = reason;
         lr.Spread     = spreadClose;
         lr.Dist       = 0;
         lr.GridPips   = GridPips;
         lr.s          = s;
         lr.lotFactor  = 0;
         lr.BaseLot    = BaseLot;
         lr.MaxLot     = MaxLot;
         lr.actualLot  = actualLot;
         lr.seqStr     = seqTmp;
         lr.CommentTag = comment;
         lr.Magic      = MagicNumber;
         lr.OrderType  = OrderTypeToStr(type);
         lr.EntryPrice = entryPrice;
         lr.SL         = slVal;
         lr.TP         = tpVal;
         lr.ErrorCode  = err;
         WriteLog(lr);
         if(!ok)
            PrintFormat("CloseAllOrders: failed to close %d err=%d", ticket, err);
         else if(updateDMC)
            ProcessClosedTrades(sysTmp, true, reason);
      }
      else if(type == OP_BUYLIMIT || type == OP_SELLLIMIT ||
              type == OP_BUYSTOP  || type == OP_SELLSTOP)
      {
         if(!RefreshRatesChecked(__FUNCTION__))
         {
            PrintFormat("CloseAllOrders: RefreshRatesChecked failed, skip ticket %d", ticket);
            continue;
         }
         double spreadPend = PriceToPips(MathAbs(Ask - Bid));
         int err = 0;
         ResetLastError();
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
         lr.Spread     = spreadPend;
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
   if(!RefreshRatesChecked(__FUNCTION__))
      return;

   int slippage = (int)MathRound(SlippagePips * Pip() / _Point);

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
         int type          = OrderType();
         if(!RefreshRatesChecked(__FUNCTION__))
            return;
         double price      = (type == OP_BUY) ? Bid : Ask;
         price = NormalizeDouble(price, _Digits);
         double lot        = OrderLots();
         string comment    = OrderComment();
         double entryPrice = OrderOpenPrice();
         double slVal      = OrderStopLoss();
         double tpVal      = OrderTakeProfit();
         string sysTmp, seqTmp;
         ParseComment(comment, sysTmp, seqTmp);
         int err = 0;
         ResetLastError();
         bool ok = OrderClose(tk, lot, price, slippage, clrNONE);
         if(!ok)
            err = GetLastError();
         LogRecord lr;
         lr.Time       = TimeCurrent();
         lr.Symbol     = Symbol();
         lr.System     = "A";
         lr.Reason     = "RESET_ALIVE";
         lr.Spread     = PriceToPips(MathAbs(Ask - Bid));
         lr.Dist       = 0;
         lr.GridPips   = GridPips;
         lr.s          = s;
         lr.lotFactor  = 0;
         lr.BaseLot    = BaseLot;
         lr.MaxLot     = MaxLot;
         lr.actualLot  = lot;
         lr.seqStr     = seqTmp;
         lr.CommentTag = comment;
         lr.Magic      = MagicNumber;
         lr.OrderType  = OrderTypeToStr(type);
         lr.EntryPrice = entryPrice;
         lr.SL         = slVal;
         lr.TP         = tpVal;
         lr.ErrorCode  = err;
         WriteLog(lr);
         if(!ok)
            PrintFormat("CorrectDuplicatePositions: failed to close %d err=%d", tk, err);
      }
      InitCloseTimes();
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
         int type          = OrderType();
         if(!RefreshRatesChecked(__FUNCTION__))
            return;
         double price      = (type == OP_BUY) ? Bid : Ask;
         price = NormalizeDouble(price, _Digits);
         double lot        = OrderLots();
         string comment    = OrderComment();
         double entryPrice = OrderOpenPrice();
         double slVal      = OrderStopLoss();
         double tpVal      = OrderTakeProfit();
         string sysTmp2, seqTmp2;
         ParseComment(comment, sysTmp2, seqTmp2);
         int err = 0;
         ResetLastError();
         bool ok = OrderClose(tk, lot, price, slippage, clrNONE);
         if(!ok)
            err = GetLastError();
         LogRecord lr;
         lr.Time       = TimeCurrent();
         lr.Symbol     = Symbol();
         lr.System     = "B";
         lr.Reason     = "RESET_ALIVE";
         lr.Spread     = PriceToPips(MathAbs(Ask - Bid));
         lr.Dist       = 0;
         lr.GridPips   = GridPips;
         lr.s          = s;
         lr.lotFactor  = 0;
         lr.BaseLot    = BaseLot;
         lr.MaxLot     = MaxLot;
         lr.actualLot  = lot;
         lr.seqStr     = seqTmp2;
         lr.CommentTag = comment;
         lr.Magic      = MagicNumber;
         lr.OrderType  = OrderTypeToStr(type);
         lr.EntryPrice = entryPrice;
         lr.SL         = slVal;
         lr.TP         = tpVal;
         lr.ErrorCode  = err;
         WriteLog(lr);
         if(!ok)
            PrintFormat("CorrectDuplicatePositions: failed to close %d err=%d", tk, err);
      }
      InitCloseTimes();
      DeletePendings("B", "RESET_ALIVE");
   }
}

//+------------------------------------------------------------------+
//| Place refill pending orders at ±s from reference price           |
//+------------------------------------------------------------------+
bool PlaceRefillOrders(const string system,const double refPrice)
{
   if(!RefreshRatesChecked(__FUNCTION__))
      return(false);

   string seq;
   double lotFactor;
   double lot = CalcLot(system, seq, lotFactor);
   if(lot <= 0)
      return(false);

   string comment  = MakeComment(system, seq);
   double priceSell = refPrice + PipsToPrice(s);
   double priceBuy  = refPrice - PipsToPrice(s);
   priceSell = NormalizeDouble(priceSell, _Digits);
   priceBuy  = NormalizeDouble(priceBuy, _Digits);
   int ticketSell = -1;
   int ticketBuy  = -1;
   bool okSell = true;
   bool okBuy  = true;

   string errSell;
   if(!CanPlaceOrder(priceSell, false, errSell))
   {
      LogRecord lr;
      lr.Time       = TimeCurrent();
      lr.Symbol     = Symbol();
      lr.System     = system;
      lr.Reason     = "REFILL";
      lr.Spread     = PriceToPips(MathAbs(Ask - Bid));
      lr.Dist       = MathMax(DistanceToExistingPositions(priceSell), 0);
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
      int codeSell  = 0;
      if(errSell == "FreezeLevel violation")
         codeSell = ERR_INVALID_STOPS;
      else if(errSell == "Wrong direction")
         codeSell = ERR_INVALID_PRICE;
      else if(errSell == "DistanceBandViolation")
         codeSell = ERR_DISTANCE_BAND;
      else if(errSell == "SpreadExceeded")
         codeSell = ERR_SPREAD_EXCEEDED;
      lr.ErrorCode  = codeSell;
      string infoSell = errSell;
      if(errSell == "DistanceBandViolation")
         infoSell = "Distance band violation";
      else if(errSell == "SpreadExceeded")
         infoSell = "Spread exceeded";
      lr.ErrorInfo  = infoSell;
      WriteLog(lr);
      okSell = false;
   }
   else
   {
      if(!RefreshRatesChecked(__FUNCTION__))
         return(false);
      ResetLastError();
      ticketSell = OrderSend(Symbol(), OP_SELLLIMIT, lot, priceSell,
                             0, 0, 0, comment, MagicNumber, 0, clrNONE);
      if(ticketSell >= 0)
         StoreLotFactor(ticketSell, lotFactor);
      LogRecord lr;
      lr.Time       = TimeCurrent();
      lr.Symbol     = Symbol();
      lr.System     = system;
      lr.Reason     = "REFILL";
      lr.Spread     = PriceToPips(MathAbs(Ask - Bid));
      lr.Dist       = MathMax(DistanceToExistingPositions(priceSell), 0);
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

   string errBuy;
   if(!CanPlaceOrder(priceBuy, true, errBuy))
   {
      LogRecord lrb;
      lrb.Time       = TimeCurrent();
      lrb.Symbol     = Symbol();
      lrb.System     = system;
      lrb.Reason     = "REFILL";
      lrb.Spread     = PriceToPips(MathAbs(Ask - Bid));
      lrb.Dist       = MathMax(DistanceToExistingPositions(priceBuy), 0);
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
      int codeBuy    = 0;
      if(errBuy == "FreezeLevel violation")
         codeBuy = ERR_INVALID_STOPS;
      else if(errBuy == "Wrong direction")
         codeBuy = ERR_INVALID_PRICE;
      else if(errBuy == "DistanceBandViolation")
         codeBuy = ERR_DISTANCE_BAND;
      else if(errBuy == "SpreadExceeded")
         codeBuy = ERR_SPREAD_EXCEEDED;
      lrb.ErrorCode  = codeBuy;
      string infoBuy = errBuy;
      if(errBuy == "DistanceBandViolation")
         infoBuy = "Distance band violation";
      else if(errBuy == "SpreadExceeded")
         infoBuy = "Spread exceeded";
      lrb.ErrorInfo  = infoBuy;
      WriteLog(lrb);
      okBuy = false;
   }
   else
   {
      if(!RefreshRatesChecked(__FUNCTION__))
         return(false);
      ResetLastError();
      ticketBuy = OrderSend(Symbol(), OP_BUYLIMIT, lot, priceBuy,
                            0, 0, 0, comment, MagicNumber, 0, clrNONE);
      if(ticketBuy >= 0)
         StoreLotFactor(ticketBuy, lotFactor);
      LogRecord lr2;
      lr2.Time       = TimeCurrent();
      lr2.Symbol     = Symbol();
      lr2.System     = system;
      lr2.Reason     = "REFILL";
      lr2.Spread     = PriceToPips(MathAbs(Ask - Bid));
      lr2.Dist       = MathMax(DistanceToExistingPositions(priceBuy), 0);
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

   if(okSell && !okBuy && ticketSell >= 0)
   {
      int err = 0;
      ResetLastError();
      bool delOk = OrderDelete(ticketSell);
      if(!delOk)
         err = GetLastError();

      LogRecord lrd;
      lrd.Time       = TimeCurrent();
      lrd.Symbol     = Symbol();
      lrd.System     = system;
      lrd.Reason     = "REFILL";
      lrd.Spread     = PriceToPips(MathAbs(Ask - Bid));
      lrd.Dist       = MathMax(DistanceToExistingPositions(priceSell), 0);
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
      ResetLastError();
      bool delOk = OrderDelete(ticketBuy);
      if(!delOk)
         err = GetLastError();

      LogRecord lrd;
      lrd.Time       = TimeCurrent();
      lrd.Symbol     = Symbol();
      lrd.System     = system;
      lrd.Reason     = "REFILL";
      lrd.Spread     = PriceToPips(MathAbs(Ask - Bid));
      lrd.Dist       = MathMax(DistanceToExistingPositions(priceBuy), 0);
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

   return(okSell && okBuy);
}

//+------------------------------------------------------------------+
//| Place initial market order for system A and OCO limits for B     |
//+------------------------------------------------------------------+
bool InitStrategy()
{
   if(!RefreshRatesChecked(__FUNCTION__))
      return(false);

   //---- system A market order
   string seqA; double lotFactorA; double lotA = CalcLot("A", seqA, lotFactorA);
   if(lotA <= 0) return(false);

   bool isBuy = (MathRand() % 2) == 0;
   int    slippage = (int)MathRound(SlippagePips * Pip() / _Point);
   double price    = isBuy ? Ask : Bid;
   price           = NormalizeDouble(price, _Digits);
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

   double stopLevel   = MarketInfo(Symbol(), MODE_STOPLEVEL) * _Point;
   double freezeLevel = MarketInfo(Symbol(), MODE_FREEZELEVEL) * _Point;
   double minLevel    = MathMax(stopLevel, freezeLevel);

   double distSL = MathAbs(price - entrySL);
   if(distSL < minLevel)
   {
      double oldSL = entrySL;
      entrySL = isBuy ? price - minLevel : price + minLevel;
      entrySL = NormalizeDouble(entrySL, _Digits);
      PrintFormat("InitStrategy: SL adjusted from %.*f to %.*f due to min distance %.1f pips",
                  _Digits, oldSL, _Digits, entrySL, PriceToPips(minLevel));
   }

   double distTP = MathAbs(entryTP - price);
   if(distTP < minLevel)
   {
      double oldTP = entryTP;
      entryTP = isBuy ? price + minLevel : price - minLevel;
      entryTP = NormalizeDouble(entryTP, _Digits);
      PrintFormat("InitStrategy: TP adjusted from %.*f to %.*f due to min distance %.1f pips",
                  _Digits, oldTP, _Digits, entryTP, PriceToPips(minLevel));
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
      lrSkipA.Spread     = PriceToPips(MathAbs(Ask - Bid));
      lrSkipA.Dist       = MathMax(distA, 0);
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
      lrSkipA.ErrorCode  = ERR_DISTANCE_BAND;
      lrSkipA.ErrorInfo  = "Distance band violation";
      WriteLog(lrSkipA);
      PrintFormat("InitStrategy: distance %.1f outside band [%.1f, %.1f], order skipped",
                  distA, MinDistancePips, MaxDistancePips);
      return(false);
   }
   int typeA   = isBuy ? OP_BUY : OP_SELL;
   double oldPrice = price;
   if(!RefreshRatesChecked(__FUNCTION__))
      return(false);
   price = isBuy ? Ask : Bid;
   price = NormalizeDouble(price, _Digits);
   if(price != oldPrice)
   {
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

      distSL = MathAbs(price - entrySL);
      if(distSL < minLevel)
      {
         double oldSL = entrySL;
         entrySL = isBuy ? price - minLevel : price + minLevel;
         entrySL = NormalizeDouble(entrySL, _Digits);
         PrintFormat("InitStrategy: SL adjusted from %.*f to %.*f due to min distance %.1f pips",
                     _Digits, oldSL, _Digits, entrySL, PriceToPips(minLevel));
      }

      distTP = MathAbs(entryTP - price);
      if(distTP < minLevel)
      {
         double oldTP = entryTP;
         entryTP = isBuy ? price + minLevel : price - minLevel;
         entryTP = NormalizeDouble(entryTP, _Digits);
         PrintFormat("InitStrategy: TP adjusted from %.*f to %.*f due to min distance %.1f pips",
                     _Digits, oldTP, _Digits, entryTP, PriceToPips(minLevel));
      }
   }
   distA = DistanceToExistingPositions(price);
   if(UseDistanceBand && distA >= 0 && (distA < MinDistancePips || distA > MaxDistancePips))
   {
      LogRecord lrSkipA;
      lrSkipA.Time       = TimeCurrent();
      lrSkipA.Symbol     = Symbol();
      lrSkipA.System     = "A";
      lrSkipA.Reason     = "INIT";
      lrSkipA.Spread     = PriceToPips(MathAbs(Ask - Bid));
      lrSkipA.Dist       = MathMax(distA, 0);
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
      lrSkipA.ErrorCode  = ERR_DISTANCE_BAND;
      lrSkipA.ErrorInfo  = "Distance band violation";
      WriteLog(lrSkipA);
      PrintFormat("InitStrategy: distance %.1f outside band [%.1f, %.1f], order skipped",
                  distA, MinDistancePips, MaxDistancePips);
      return(false);
   }

   double spread = PriceToPips(MathAbs(Ask - Bid)); // 参考情報のみ（成行では判定しない）

   price       = NormalizeDouble(price, _Digits);
   ResetLastError();
   int ticketA = OrderSend(Symbol(), typeA, lotA, price,
                           slippage, entrySL, entryTP, commentA, MagicNumber, 0, clrNONE);
   if(ticketA >= 0)
      StoreLotFactor(ticketA, lotFactorA);
   LogRecord lrA;
   lrA.Time       = TimeCurrent();
   lrA.Symbol     = Symbol();
   lrA.System     = "A";
   lrA.Reason     = "INIT";
   lrA.Spread     = spread;
   lrA.Dist       = MathMax(distA, 0);
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
   // system A 成行成立を記録
   state_A = Alive;
   double entryPrice = OrderOpenPrice();

   EnsureShadowOrder(ticketA, "A");

   //---- system B OCO pending orders
   string seqB; double lotFactorB; double lotB = CalcLot("B", seqB, lotFactorB);
   if(lotB <= 0)
   {
      state_B = None;
      return(false);
   }
   string commentB = MakeComment("B", seqB);

   double priceSell = entryPrice + PipsToPrice(s);
   double priceBuy  = entryPrice - PipsToPrice(s);
   stopLevel   = MarketInfo(Symbol(), MODE_STOPLEVEL) * _Point;
   freezeLevel = MarketInfo(Symbol(), MODE_FREEZELEVEL) * _Point;

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
      lrS.Spread     = PriceToPips(MathAbs(Ask - Bid));
      lrS.Dist       = MathMax(distBand, 0);
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
      // Freeze level violation
      lrS.ErrorCode  = ERR_INVALID_STOPS;
      lrS.ErrorInfo  = "Freeze level violation";
      WriteLog(lrS);
      PrintFormat("InitStrategy: SellLimit %.*f within freeze level %.1f pips, retry next tick",
                  _Digits, priceSell, PriceToPips(freezeLevel));
      okSell = false;
   }
   else
   {
      if(distSell < stopLevel)
      {
         double oldS = priceSell;
         priceSell = NormalizeDouble(Bid + stopLevel, _Digits);
         PrintFormat("InitStrategy: SellLimit adjusted from %.*f to %.*f due to stop level %.1f pips",
                     _Digits, oldS, _Digits, priceSell, PriceToPips(stopLevel));
      }
      double distBand = DistanceToExistingPositions(priceSell);
      if(UseDistanceBand && distBand >= 0 && (distBand < MinDistancePips || distBand > MaxDistancePips))
      {
         LogRecord lrS;
         lrS.Time       = TimeCurrent();
         lrS.Symbol     = Symbol();
         lrS.System     = "B";
         lrS.Reason     = "INIT";
         lrS.Spread     = PriceToPips(MathAbs(Ask - Bid));
         lrS.Dist       = MathMax(distBand, 0);
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
         lrS.ErrorCode  = ERR_DISTANCE_BAND;
         lrS.ErrorInfo  = "Distance band violation";
         WriteLog(lrS);
         PrintFormat("InitStrategy: SellLimit distance %.1f outside band [%.1f, %.1f]",
                     distBand, MinDistancePips, MaxDistancePips);
         okSell = false;
      }
      else
      {
         string errS;
         if(!CanPlaceOrder(priceSell, false, errS))
         {
            LogRecord lrS;
            lrS.Time       = TimeCurrent();
            lrS.Symbol     = Symbol();
            lrS.System     = "B";
            lrS.Reason     = "INIT";
            lrS.Spread     = PriceToPips(MathAbs(Ask - Bid));
            lrS.Dist       = MathMax(distBand, 0);
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
            int codeS = 0;
            if(errS == "DistanceBandViolation")
               codeS = ERR_DISTANCE_BAND;
            else if(errS == "SpreadExceeded")
               codeS = ERR_SPREAD_EXCEEDED;
            lrS.ErrorCode  = codeS;
            string infoS = errS;
            if(errS == "DistanceBandViolation")
               infoS = "Distance band violation";
            else if(errS == "SpreadExceeded")
               infoS = "Spread exceeded";
            lrS.ErrorInfo  = infoS;
            WriteLog(lrS);
            okSell = false;
         }
      else
      {
         if(!RefreshRatesChecked(__FUNCTION__))
            return(false);
         ResetLastError();
         ticketSell = OrderSend(Symbol(), OP_SELLLIMIT, lotB, priceSell,
                                0, 0, 0, commentB, MagicNumber, 0, clrNONE);
         if(ticketSell >= 0)
            StoreLotFactor(ticketSell, lotFactorB);
         LogRecord lrS;
         lrS.Time       = TimeCurrent();
         lrS.Symbol     = Symbol();
            lrS.System     = "B";
            lrS.Reason     = "INIT";
            lrS.Spread     = PriceToPips(MathAbs(Ask - Bid));
            lrS.Dist       = MathMax(distBand, 0);
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
      lrB.Spread     = PriceToPips(MathAbs(Ask - Bid));
      lrB.Dist       = MathMax(distBandB, 0);
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
      // Freeze level violation
      lrB.ErrorCode  = ERR_INVALID_STOPS;
      lrB.ErrorInfo  = "Freeze level violation";
      WriteLog(lrB);
      PrintFormat("InitStrategy: BuyLimit %.*f within freeze level %.1f pips, retry next tick",
                  _Digits, priceBuy, PriceToPips(freezeLevel));
      okBuy = false;
   }
   else
   {
      if(distBuy < stopLevel)
      {
         double oldB = priceBuy;
         priceBuy = NormalizeDouble(Ask - stopLevel, _Digits);
         PrintFormat("InitStrategy: BuyLimit adjusted from %.*f to %.*f due to stop level %.1f pips",
                     _Digits, oldB, _Digits, priceBuy, PriceToPips(stopLevel));
      }
      double distBandB = DistanceToExistingPositions(priceBuy);
      if(UseDistanceBand && distBandB >= 0 && (distBandB < MinDistancePips || distBandB > MaxDistancePips))
      {
         LogRecord lrB;
         lrB.Time       = TimeCurrent();
         lrB.Symbol     = Symbol();
         lrB.System     = "B";
         lrB.Reason     = "INIT";
         lrB.Spread     = PriceToPips(MathAbs(Ask - Bid));
         lrB.Dist       = MathMax(distBandB, 0);
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
        lrB.ErrorCode  = ERR_DISTANCE_BAND;
        lrB.ErrorInfo  = "Distance band violation";
        WriteLog(lrB);
        PrintFormat("InitStrategy: BuyLimit distance %.1f outside band [%.1f, %.1f]",
                    distBandB, MinDistancePips, MaxDistancePips);
        okBuy = false;
      }
      else
      {
         string errB;
         if(!CanPlaceOrder(priceBuy, true, errB))
         {
            LogRecord lrB;
            lrB.Time       = TimeCurrent();
            lrB.Symbol     = Symbol();
            lrB.System     = "B";
            lrB.Reason     = "INIT";
            lrB.Spread     = PriceToPips(MathAbs(Ask - Bid));
            lrB.Dist       = MathMax(distBandB, 0);
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
            int codeB = 0;
            if(errB == "DistanceBandViolation")
               codeB = ERR_DISTANCE_BAND;
            else if(errB == "SpreadExceeded")
               codeB = ERR_SPREAD_EXCEEDED;
            lrB.ErrorCode  = codeB;
            string infoB = errB;
            if(errB == "DistanceBandViolation")
               infoB = "Distance band violation";
            else if(errB == "SpreadExceeded")
               infoB = "Spread exceeded";
            lrB.ErrorInfo  = infoB;
            WriteLog(lrB);
            okBuy = false;
         }
      else
      {
         if(!RefreshRatesChecked(__FUNCTION__))
            return(false);
         ResetLastError();
         ticketBuy = OrderSend(Symbol(), OP_BUYLIMIT, lotB, priceBuy,
                               0, 0, 0, commentB, MagicNumber, 0, clrNONE);
         if(ticketBuy >= 0)
            StoreLotFactor(ticketBuy, lotFactorB);
         LogRecord lrB;
         lrB.Time       = TimeCurrent();
         lrB.Symbol     = Symbol();
            lrB.System     = "B";
            lrB.Reason     = "INIT";
         lrB.Spread     = PriceToPips(MathAbs(Ask - Bid));
         lrB.Dist       = MathMax(distBandB, 0);
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
      ResetLastError();
      bool delOk = OrderDelete(ticketSell);
      if(!delOk)
         err = GetLastError();

      LogRecord lrd;
      lrd.Time       = TimeCurrent();
      lrd.Symbol     = Symbol();
      lrd.System     = "B";
      lrd.Reason     = "INIT";
      lrd.Spread     = PriceToPips(MathAbs(Ask - Bid));
      lrd.Dist       = MathMax(DistanceToExistingPositions(priceSell), 0);
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
      state_B = None;
      return(false);
   }
   if(okBuy && !okSell && ticketBuy >= 0)
   {
      int err = 0;
      ResetLastError();
      bool delOk = OrderDelete(ticketBuy);
      if(!delOk)
         err = GetLastError();

      LogRecord lrd;
      lrd.Time       = TimeCurrent();
      lrd.Symbol     = Symbol();
      lrd.System     = "B";
      lrd.Reason     = "INIT";
      lrd.Spread     = PriceToPips(MathAbs(Ask - Bid));
      lrd.Dist       = MathMax(DistanceToExistingPositions(priceBuy), 0);
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
      state_B = None;
      return(false);
   }

   bool result = okBuy && okSell;
   state_B = result ? Missing : None;
   return(result);
  }

//+------------------------------------------------------------------+
//| Detect filled OCO for specified system                            |
//+------------------------------------------------------------------+
void HandleOCODetectionFor(const string system)
{
   ProcessClosedTrades(system, true);
   if(!RefreshRatesChecked(__FUNCTION__))
      return;
   int posTicket = -1;
   int retryType = -1;
   if(system == "A")
   {
      if(retryTicketA > 0)
      {
         if(OrderSelect(retryTicketA, SELECT_BY_TICKET))
            posTicket = retryTicketA;
         else
            retryTicketA = -1;
      }
      else if(retryTicketA == 0)
         retryType = retryTypeA;
   }
   else
   {
      if(retryTicketB > 0)
      {
         if(OrderSelect(retryTicketB, SELECT_BY_TICKET))
            posTicket = retryTicketB;
         else
            retryTicketB = -1;
      }
      else if(retryTicketB == 0)
         retryType = retryTypeB;
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
   if(posTicket == -1 && retryType != -1)
   {
      string seqAdj; double lotFactorAdj;
      double expectedLot = CalcLot(system, seqAdj, lotFactorAdj);
      if(expectedLot <= 0)
      {
         string tmpComment = MakeComment(system, seqAdj);
         LogRecord lrSkip;
         lrSkip.Time       = TimeCurrent();
         lrSkip.Symbol     = Symbol();
         lrSkip.System     = system;
         lrSkip.Reason     = "REFILL";
         lrSkip.Spread     = PriceToPips(MathAbs(Ask - Bid));
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
         return;
      }
      string expectedComment = MakeComment(system, seqAdj);
      if(!RefreshRatesChecked(__FUNCTION__))
         return;
      double price = (retryType == OP_BUY) ? Ask : Bid;
      double dist = DistanceToExistingPositions(price);
      int slippage = (int)MathRound(SlippagePips * Pip() / _Point);
      double slInit = (retryType == OP_BUY) ? price - PipsToPrice(GridPips) : price + PipsToPrice(GridPips);
      double tpInit = (retryType == OP_BUY) ? price + PipsToPrice(GridPips) : price - PipsToPrice(GridPips);
      double stopLevel   = MarketInfo(Symbol(), MODE_STOPLEVEL)   * _Point;
      double freezeLevel = MarketInfo(Symbol(), MODE_FREEZELEVEL) * _Point;
      double distSL      = MathAbs(price - slInit);
      double distTP      = MathAbs(tpInit - price);
      if(distSL < stopLevel)
      {
         slInit = (retryType == OP_BUY) ? price - stopLevel : price + stopLevel;
         slInit = NormalizeDouble(slInit, _Digits);
      }
      if(distTP < stopLevel)
      {
         tpInit = (retryType == OP_BUY) ? price + stopLevel : price - stopLevel;
         tpInit = NormalizeDouble(tpInit, _Digits);
      }
      if(distSL < freezeLevel || distTP < freezeLevel)
      {
         LogRecord lrFail;
         lrFail.Time       = TimeCurrent();
         lrFail.Symbol     = Symbol();
         lrFail.System     = system;
         lrFail.Reason     = "REFILL";
         lrFail.Spread     = PriceToPips(MathAbs(Ask - Bid));
         lrFail.Dist       = MathMax(dist, 0);
         lrFail.GridPips   = GridPips;
         lrFail.s          = s;
         lrFail.lotFactor  = lotFactorAdj;
         lrFail.BaseLot    = BaseLot;
         lrFail.MaxLot     = MaxLot;
         lrFail.actualLot  = expectedLot;
         lrFail.seqStr     = seqAdj;
         lrFail.CommentTag = expectedComment;
         lrFail.Magic      = MagicNumber;
         lrFail.OrderType  = OrderTypeToStr(retryType);
         lrFail.EntryPrice = price;
         lrFail.SL         = slInit;
         lrFail.TP         = tpInit;
         lrFail.ErrorCode  = ERR_INVALID_STOPS;
         lrFail.ErrorInfo  = "SL/TP within freeze level";
         WriteLog(lrFail);
         return;
      }
      slInit = NormalizeDouble(slInit, _Digits);
      tpInit = NormalizeDouble(tpInit, _Digits);
      if((retryType == OP_BUY && (slInit >= price || tpInit <= price)) ||
         (retryType == OP_SELL && (slInit <= price || tpInit >= price)))
      {
         LogRecord lrFail;
         lrFail.Time       = TimeCurrent();
         lrFail.Symbol     = Symbol();
         lrFail.System     = system;
         lrFail.Reason     = "REFILL";
         lrFail.Spread     = PriceToPips(MathAbs(Ask - Bid));
         lrFail.Dist       = MathMax(dist, 0);
         lrFail.GridPips   = GridPips;
         lrFail.s          = s;
         lrFail.lotFactor  = lotFactorAdj;
         lrFail.BaseLot    = BaseLot;
         lrFail.MaxLot     = MaxLot;
         lrFail.actualLot  = expectedLot;
         lrFail.seqStr     = seqAdj;
         lrFail.CommentTag = expectedComment;
         lrFail.Magic      = MagicNumber;
         lrFail.OrderType  = OrderTypeToStr(retryType);
         lrFail.EntryPrice = price;
         lrFail.SL         = slInit;
         lrFail.TP         = tpInit;
         lrFail.ErrorCode  = ERR_INVALID_STOPS;
         lrFail.ErrorInfo  = "SL/TP on wrong side after adjustment";
         WriteLog(lrFail);
         return;
      }
      if(!RefreshRatesChecked(__FUNCTION__))
         return;
      double spread = PriceToPips(MathAbs(Ask - Bid));
      if(MaxSpreadPips > 0 && spread > MaxSpreadPips)
      {
         LogRecord lrFail;
         lrFail.Time       = TimeCurrent();
         lrFail.Symbol     = Symbol();
         lrFail.System     = system;
         lrFail.Reason     = "REFILL";
         lrFail.Spread     = spread;
         lrFail.Dist       = MathMax(dist, 0);
         lrFail.GridPips   = GridPips;
         lrFail.s          = s;
         lrFail.lotFactor  = lotFactorAdj;
         lrFail.BaseLot    = BaseLot;
         lrFail.MaxLot     = MaxLot;
         lrFail.actualLot  = expectedLot;
         lrFail.seqStr     = seqAdj;
         lrFail.CommentTag = expectedComment;
         lrFail.Magic      = MagicNumber;
         lrFail.OrderType  = OrderTypeToStr(retryType);
         lrFail.EntryPrice = price;
         lrFail.SL         = slInit;
         lrFail.TP         = tpInit;
         lrFail.ErrorCode  = ERR_SPREAD_EXCEEDED;
         lrFail.ErrorInfo  = "Spread exceeded";
         WriteLog(lrFail);
         return;
      }
      ResetLastError();
      int newTicket = OrderSend(Symbol(), retryType, expectedLot, price,
                                slippage, slInit, tpInit,
                                expectedComment, MagicNumber, 0, clrNONE);
      if(newTicket >= 0)
         StoreLotFactor(newTicket, lotFactorAdj);
      if(newTicket < 0)
      {
         int errCode = GetLastError();
         LogRecord lrFail;
         lrFail.Time       = TimeCurrent();
         lrFail.Symbol     = Symbol();
         lrFail.System     = system;
         lrFail.Reason     = "REFILL";
         lrFail.Spread     = spread;
         lrFail.Dist       = MathMax(dist, 0);
         lrFail.GridPips   = GridPips;
         lrFail.s          = s;
         lrFail.lotFactor  = lotFactorAdj;
         lrFail.BaseLot    = BaseLot;
         lrFail.MaxLot     = MaxLot;
         lrFail.actualLot  = expectedLot;
         lrFail.seqStr     = seqAdj;
         lrFail.CommentTag = expectedComment;
         lrFail.Magic      = MagicNumber;
         lrFail.OrderType  = OrderTypeToStr(retryType);
         lrFail.EntryPrice = price;
         lrFail.SL         = slInit;
         lrFail.TP         = tpInit;
         lrFail.ErrorCode  = errCode;
         lrFail.ErrorInfo  = ErrorDescriptionWrap(errCode);
         WriteLog(lrFail);
         if(system == "A")
         {
            state_A      = Missing;
            retryTicketA = 0;
            retryTypeA   = retryType;
         }
         else
         {
            state_B      = Missing;
            retryTicketB = 0;
            retryTypeB   = retryType;
         }
         return;
      }
      posTicket = newTicket;
      if(system == "A")
         retryTicketA = newTicket;
      else
         retryTicketB = newTicket;
      if(!OrderSelect(posTicket, SELECT_BY_TICKET))
      {
         if(system == "A")
            state_A = None;
         else
            state_B = None;
         return;
      }
   }
   if(posTicket == -1)
   {
      if(system == "A")
      {
         retryTicketA = -1;
         retryTypeA   = -1;
      }
      else
      {
         retryTicketB = -1;
         retryTypeB   = -1;
      }
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
         lrSkip.Spread     = PriceToPips(MathAbs(Ask - Bid));
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
   double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);
   double lotTol  = (lotStep > 0) ? lotStep * 0.5 : 1e-8;
   if(MathAbs(OrderLots() - expectedLot) > lotTol || OrderComment() != expectedComment)
   {
      if(!RefreshRatesChecked(__FUNCTION__))
         return;
      double spreadClose = PriceToPips(MathAbs(Ask - Bid));
      int    type      = OrderType();
      double oldLots   = OrderLots();
      double closePrice = (type == OP_BUY) ? Bid : Ask;
      closePrice = NormalizeDouble(closePrice, _Digits);
      string sysTmp, oldSeq; ParseComment(OrderComment(), sysTmp, oldSeq);
      int slippage = (int)MathRound(SlippagePips * Pip() / _Point);
      int errClose = 0;
      ResetLastError();
      if(!OrderClose(posTicket, oldLots, closePrice, slippage, clrNONE))
         errClose = GetLastError();
      LogRecord lrClose;
      lrClose.Time       = TimeCurrent();
      lrClose.Symbol     = Symbol();
      lrClose.System     = system;
      lrClose.Reason     = "REFILL";
      lrClose.Spread     = spreadClose;
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

      ProcessClosedTrades(system, false, "REFILL");
      if(!RefreshRatesChecked(__FUNCTION__))
         return;
      double price = (type == OP_BUY) ? Ask : Bid;
      double dist = DistanceToExistingPositions(price);
      slippage = (int)MathRound(SlippagePips * Pip() / _Point);
      double slInit, tpInit;
      if(type == OP_BUY)
      {
         slInit = price - PipsToPrice(GridPips);
         tpInit = price + PipsToPrice(GridPips);
      }
      else
      {
         slInit = price + PipsToPrice(GridPips);
         tpInit = price - PipsToPrice(GridPips);
      }
      double stopLevel   = MarketInfo(Symbol(), MODE_STOPLEVEL)   * _Point;
      double freezeLevel = MarketInfo(Symbol(), MODE_FREEZELEVEL) * _Point;
      double distSL      = MathAbs(price - slInit);
      double distTP      = MathAbs(tpInit - price);
      if(distSL < stopLevel)
      {
         double old = slInit;
         slInit = (type == OP_BUY) ? price - stopLevel : price + stopLevel;
         slInit = NormalizeDouble(slInit, _Digits);
         PrintFormat("HandleOCODetectionFor: SL adjusted from %.*f to %.*f due to stop level %.1f pips",
                     _Digits, old, _Digits, slInit, PriceToPips(stopLevel));
         distSL = MathAbs(price - slInit);
      }
      if(distTP < stopLevel)
      {
         double old = tpInit;
         tpInit = (type == OP_BUY) ? price + stopLevel : price - stopLevel;
         tpInit = NormalizeDouble(tpInit, _Digits);
         PrintFormat("HandleOCODetectionFor: TP adjusted from %.*f to %.*f due to stop level %.1f pips",
                     _Digits, old, _Digits, tpInit, PriceToPips(stopLevel));
         distTP = MathAbs(tpInit - price);
      }
      if(distSL < freezeLevel || distTP < freezeLevel)
      {
         LogRecord lrFail;
         lrFail.Time       = TimeCurrent();
         lrFail.Symbol     = Symbol();
         lrFail.System     = system;
         lrFail.Reason     = "REFILL";
         lrFail.Spread     = PriceToPips(MathAbs(Ask - Bid));
         lrFail.Dist       = MathMax(dist, 0);
         lrFail.GridPips   = GridPips;
         lrFail.s          = s;
         lrFail.lotFactor  = lotFactorAdj;
         lrFail.BaseLot    = BaseLot;
         lrFail.MaxLot     = MaxLot;
         lrFail.actualLot  = expectedLot;
         lrFail.seqStr     = seqAdj;
         lrFail.CommentTag = expectedComment;
         lrFail.Magic      = MagicNumber;
         lrFail.OrderType  = OrderTypeToStr(type);
         lrFail.EntryPrice = price;
         lrFail.SL         = slInit;
         lrFail.TP         = tpInit;
         lrFail.ErrorCode  = ERR_INVALID_STOPS;
         lrFail.ErrorInfo  = "SL/TP within freeze level";
         WriteLog(lrFail);
         PrintFormat("HandleOCODetectionFor: SL/TP within freeze level %.1f pips, retry next tick",
                     PriceToPips(freezeLevel));
         if(system == "A")
         {
            retryTicketA = 0;
            retryTypeA   = type;
            state_A      = None;
         }
         else
         {
            retryTicketB = 0;
            retryTypeB   = type;
            state_B      = None;
         }
         return;
      }
      slInit = NormalizeDouble(slInit, _Digits);
      tpInit = NormalizeDouble(tpInit, _Digits);
      if((type == OP_BUY && (slInit >= price || tpInit <= price)) ||
         (type == OP_SELL && (slInit <= price || tpInit >= price)))
      {
         LogRecord lrFail;
         lrFail.Time       = TimeCurrent();
         lrFail.Symbol     = Symbol();
         lrFail.System     = system;
         lrFail.Reason     = "REFILL";
         lrFail.Spread     = PriceToPips(MathAbs(Ask - Bid));
         lrFail.Dist       = MathMax(dist, 0);
         lrFail.GridPips   = GridPips;
         lrFail.s          = s;
         lrFail.lotFactor  = lotFactorAdj;
         lrFail.BaseLot    = BaseLot;
         lrFail.MaxLot     = MaxLot;
         lrFail.actualLot  = expectedLot;
         lrFail.seqStr     = seqAdj;
         lrFail.CommentTag = expectedComment;
         lrFail.Magic      = MagicNumber;
         lrFail.OrderType  = OrderTypeToStr(type);
         lrFail.EntryPrice = price;
         lrFail.SL         = slInit;
         lrFail.TP         = tpInit;
         lrFail.ErrorCode  = ERR_INVALID_STOPS;
         lrFail.ErrorInfo  = "SL/TP on wrong side after adjustment";
         WriteLog(lrFail);
         Print("HandleOCODetectionFor: SL/TP on wrong side after adjustment, retry next tick");
         if(system == "A")
         {
            retryTicketA = 0;
            retryTypeA   = type;
            state_A      = None;
         }
         else
         {
            retryTicketB = 0;
            retryTypeB   = type;
            state_B      = None;
         }
         return;
      }
      if(!RefreshRatesChecked(__FUNCTION__))
         return;
      double spread = PriceToPips(MathAbs(Ask - Bid));
      if(MaxSpreadPips > 0 && spread > MaxSpreadPips)
      {
         LogRecord lrFail;
         lrFail.Time       = TimeCurrent();
         lrFail.Symbol     = Symbol();
         lrFail.System     = system;
         lrFail.Reason     = "REFILL";
         lrFail.Spread     = spread;
         lrFail.Dist       = MathMax(dist, 0);
         lrFail.GridPips   = GridPips;
         lrFail.s          = s;
         lrFail.lotFactor  = lotFactorAdj;
         lrFail.BaseLot    = BaseLot;
         lrFail.MaxLot     = MaxLot;
         lrFail.actualLot  = expectedLot;
         lrFail.seqStr     = seqAdj;
         lrFail.CommentTag = expectedComment;
         lrFail.Magic      = MagicNumber;
         lrFail.OrderType  = OrderTypeToStr(type);
         lrFail.EntryPrice = price;
         lrFail.SL         = slInit;
         lrFail.TP         = tpInit;
         lrFail.ErrorCode  = ERR_SPREAD_EXCEEDED;
         lrFail.ErrorInfo  = "Spread exceeded";
         WriteLog(lrFail);
         if(system == "A")
         {
            retryTicketA = 0;
            retryTypeA   = type;
            state_A      = None;
         }
         else
         {
            retryTicketB = 0;
            retryTypeB   = type;
            state_B      = None;
         }
         return;
      }
      ResetLastError();
      int newTicket = OrderSend(Symbol(), type, expectedLot, price,
                                slippage, slInit, tpInit,
                                expectedComment, MagicNumber, 0, clrNONE);
      if(newTicket >= 0)
         StoreLotFactor(newTicket, lotFactorAdj);
      if(newTicket < 0)
      {
         int errCode = GetLastError();
         LogRecord lrFail;
         lrFail.Time       = TimeCurrent();
         lrFail.Symbol     = Symbol();
         lrFail.System     = system;
         lrFail.Reason     = "REFILL";
         lrFail.Spread     = spread;
         lrFail.Dist       = MathMax(dist, 0);
         lrFail.GridPips   = GridPips;
         lrFail.s          = s;
         lrFail.lotFactor  = lotFactorAdj;
         lrFail.BaseLot    = BaseLot;
         lrFail.MaxLot     = MaxLot;
         lrFail.actualLot  = expectedLot;
         lrFail.seqStr     = seqAdj;
         lrFail.CommentTag = expectedComment;
         lrFail.Magic      = MagicNumber;
         lrFail.OrderType  = OrderTypeToStr(type);
         lrFail.EntryPrice = price;
         lrFail.SL         = slInit;
         lrFail.TP         = tpInit;
         lrFail.ErrorCode  = errCode;
         lrFail.ErrorInfo  = ErrorDescriptionWrap(errCode);
         WriteLog(lrFail);
         PrintFormat("HandleOCODetectionFor: failed to reopen %s position err=%d", system, errCode);
         if(system == "A")
         {
            retryTicketA = 0;
            retryTypeA   = type;
            state_A = None;
         }
         else
         {
            retryTicketB = 0;
            retryTypeB   = type;
            state_B = None;
         }
         return;
      }
      posTicket = newTicket;
      if(!OrderSelect(posTicket, SELECT_BY_TICKET))
      {
         if(system == "A")
         {
            retryTicketA = 0;
            retryTypeA   = type;
            state_A = None;
         }
         else
         {
            retryTicketB = 0;
            retryTypeB   = type;
            state_B = None;
         }
         return;
      }
   }

   if(OrderStopLoss() != 0 && OrderTakeProfit() != 0)
   {
      if(system == "A")
      {
         retryTicketA = -1;
         retryTypeA   = -1;
      }
      else
      {
         retryTicketB = -1;
         retryTypeB   = -1;
      }
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
         int delTicket  = OrderTicket();
         double lot     = OrderLots();
         string comment = OrderComment();
         int type       = OrderType();
         double entry   = OrderOpenPrice();
         double sl      = OrderStopLoss();
         double tp      = OrderTakeProfit();
         string typeStr = OrderTypeToStr(type);
         int err = 0;
         ResetLastError();
         bool ok = OrderDelete(delTicket);
         if(!ok)
            err = GetLastError();
         LogRecord lr;
         lr.Time       = TimeCurrent();
         lr.Symbol     = Symbol();
         lr.System     = system;
         lr.Reason     = "REFILL";
         lr.Spread     = PriceToPips(MathAbs(Ask - Bid));
         lr.Dist       = 0;
         lr.GridPips   = GridPips;
         lr.s          = s;
         lr.lotFactor  = 0;
         lr.BaseLot    = BaseLot;
         lr.MaxLot     = MaxLot;
         lr.actualLot  = lot;
         lr.seqStr     = seq;
         lr.CommentTag = comment;
         lr.Magic      = MagicNumber;
         lr.OrderType  = typeStr;
         lr.EntryPrice = entry;
         lr.SL         = sl;
         lr.TP         = tp;
         lr.ErrorCode  = err;
         WriteLog(lr);
         if(!ok)
            PrintFormat("Failed to delete pending order %d err=%d", delTicket, err);
      }
   }

   if(!RefreshRatesChecked(__FUNCTION__)) // 最新の Bid/Ask を取得
      return;
   double entry = OrderOpenPrice();
   double sl, tp;
   double stopLevel   = MarketInfo(Symbol(), MODE_STOPLEVEL) * _Point;
   double freezeLevel = MarketInfo(Symbol(), MODE_FREEZELEVEL) * _Point;
   double minDist     = MathMax(stopLevel, freezeLevel);
   if(OrderType() == OP_BUY)
   {
      sl = entry - PipsToPrice(GridPips);
      tp = entry + PipsToPrice(GridPips);
      if(Bid - sl < minDist)
         sl = Bid - minDist;
      if(tp - Bid < minDist)           // Bid 基準で最小距離を確認
         tp = Bid + minDist;           // Bid を基準にTPを設定
   }
   else
   {
      sl = entry + PipsToPrice(GridPips);
      tp = entry - PipsToPrice(GridPips);
      if(sl - Ask < minDist)
         sl = Ask + minDist;
      if(Ask - tp < minDist)
         tp = Ask - minDist;
   }
   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);

   int err = 0;
   ResetLastError();
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
      lrFail.Spread     = PriceToPips(MathAbs(Ask - Bid));
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
      lrFail.ErrorInfo  = ErrorDescriptionWrap(err);
      WriteLog(lrFail);

      if(system == "A")
         retryTicketA = posTicket;
      else
         retryTicketB = posTicket;
      return;
   }

   if(system == "A")
   {
      retryTicketA = -1;
      retryTypeA   = -1;
   }
   else
   {
      retryTicketB = -1;
      retryTypeB   = -1;
   }
   EnsureShadowOrder(posTicket, system);

   if(system == "A")
      state_A = Alive;
   else if(system == "B")
      state_B = Alive;

   string sys2, seq2;
   OrderSelect(posTicket, SELECT_BY_TICKET);
   ParseComment(OrderComment(), sys2, seq2);
   double entryActual = OrderOpenPrice();
   LogRecord lr;
   lr.Time       = TimeCurrent();
   lr.Symbol     = Symbol();
   lr.System     = system;
   lr.Reason     = "REFILL";
   lr.Spread     = PriceToPips(MathAbs(Ask - Bid));
   lr.Dist       = 0;
   lr.GridPips   = GridPips;
   lr.s          = s;
   lr.lotFactor  = lotFactorAdj;
   lr.BaseLot    = BaseLot;
   lr.MaxLot     = MaxLot;
   lr.actualLot  = OrderLots();
   lr.seqStr     = seq2;
   lr.CommentTag = OrderComment();
   lr.Magic      = MagicNumber;
   lr.OrderType  = OrderTypeToStr(OrderType());
   lr.EntryPrice = entryActual;
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
   {
      int vA = (int)MathRound(GlobalVariableGet(gvA));
      if(vA < None || vA > MissingRecovered)
         state_A = None;
      else
         state_A = (SystemState)vA;
   }
   else
      state_A = None;

   if(GlobalVariableCheck(gvB))
   {
      int vB = (int)MathRound(GlobalVariableGet(gvB));
      if(vB < None || vB > MissingRecovered)
         state_B = None;
      else
         state_B = (SystemState)vB;
   }
   else
      state_B = None;

   // Check for existing positions or orders for this EA
   bool hasAny = false;
   bool hasA   = false;
   bool hasB   = false;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderMagicNumber() != MagicNumber || OrderSymbol() != Symbol())
         continue;
      hasAny = true;
      int type = OrderType();
      string sys, seq;
      if(!ParseComment(OrderComment(), sys, seq))
         continue;
      if(type == OP_BUY || type == OP_SELL)
      {
         if(sys == "A")
            hasA = true;
         else if(sys == "B")
            hasB = true;
      }
      else if(type == OP_BUYLIMIT || type == OP_SELLLIMIT ||
              type == OP_BUYSTOP  || type == OP_SELLSTOP)
      {
         // pending orders exist for this EA
      }
   }

   // Detect and resolve any duplicate positions before proceeding
   CorrectDuplicatePositions();

   // Recalculate flags after potential corrections
   hasAny = false;
   hasA   = false;
   hasB   = false;
   for(int j = OrdersTotal() - 1; j >= 0; j--)
   {
      if(!OrderSelect(j, SELECT_BY_POS, MODE_TRADES))
         continue;
      if(OrderMagicNumber() != MagicNumber || OrderSymbol() != Symbol())
         continue;
      hasAny = true;
      int t2 = OrderType();
      string sys2, seq2;
      if(!ParseComment(OrderComment(), sys2, seq2))
         continue;
      if(t2 == OP_BUY || t2 == OP_SELL)
      {
         if(sys2 == "A")
            hasA = true;
         else if(sys2 == "B")
            hasB = true;
      }
   }

   SystemState prevA = state_A;
   SystemState prevB = state_B;
   state_A = UpdateState(prevA, hasA);
   state_B = UpdateState(prevB, hasB);

   MathSrand(GetTickCount());
   // Initialize close time tracking before processing historical trades
   InitCloseTimes();
   ProcessClosedTrades("A", true);
   ProcessClosedTrades("B", true);
   if(hasAny)
      Print("Existing entries found, InitStrategy skipped");
   else
   {
      if(!InitStrategy())
         Print("InitStrategy failed, will retry on next tick");
   }

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
            lr.Spread     = PriceToPips(MathAbs(Ask - Bid));
            lr.Dist       = MathMax(dist, 0);
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
            InitCloseTimes();
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
         lr.Spread     = PriceToPips(MathAbs(Ask - Bid));
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
           InitCloseTimes();
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
            pendB = PlaceRefillOrders("B", OrderOpenPrice());
      }
      else if(hasB && !hasA && !pendA && ticketB != -1)
      {
         if(OrderSelect(ticketB, SELECT_BY_TICKET))
            pendA = PlaceRefillOrders("A", OrderOpenPrice());
      }
   }

   state_A = nextA;
   state_B = nextB;

   if(hasA && shadowRetryA)
      EnsureShadowOrder(ticketA, "A");
   if(hasB && shadowRetryB)
      EnsureShadowOrder(ticketB, "B");

   if(state_A == Missing && !pendA)
      RecoverAfterSL("A");
   if(state_B == Missing && !pendB)
      RecoverAfterSL("B");
}

void OnDeinit(const int reason)
{
   string gvA = "MoveCatcher_state_A";
   string gvB = "MoveCatcher_state_B";
   ResetLastError();
   if(!GlobalVariableSet(gvA, state_A))
   {
      int err = GetLastError();
      PrintFormat("GlobalVariableSet(%s) err=%d %s", gvA, err, ErrorDescriptionWrap(err));
      LogRecord lr;
      lr.Time       = TimeCurrent();
      lr.Symbol     = Symbol();
      lr.System     = "A";
      lr.Reason     = "DEINIT";
      lr.Spread     = PriceToPips(MathAbs(Ask - Bid));
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
      lr.ErrorCode  = err;
      lr.ErrorInfo  = ErrorDescriptionWrap(err);
      WriteLog(lr);
   }

   ResetLastError();
   if(!GlobalVariableSet(gvB, state_B))
   {
      int err = GetLastError();
      PrintFormat("GlobalVariableSet(%s) err=%d %s", gvB, err, ErrorDescriptionWrap(err));
      LogRecord lr;
      lr.Time       = TimeCurrent();
      lr.Symbol     = Symbol();
      lr.System     = "B";
      lr.Reason     = "DEINIT";
      lr.Spread     = PriceToPips(MathAbs(Ask - Bid));
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
      lr.ErrorCode  = err;
      lr.ErrorInfo  = ErrorDescriptionWrap(err);
      WriteLog(lr);
   }

   int err;

   err = 0;
   bool savedA = SaveDMCState("A", stateA, err);
   if(!savedA)
   {
      PrintFormat("SaveDMCState(%s) err=%d %s", "A", err, ErrorDescriptionWrap(err));
      LogRecord lr;
      lr.Time       = TimeCurrent();
      lr.Symbol     = Symbol();
      lr.System     = "A";
      lr.Reason     = "DEINIT";
      lr.Spread     = PriceToPips(MathAbs(Ask - Bid));
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
      lr.ErrorCode  = err;
      lr.ErrorInfo  = ErrorDescriptionWrap(err);
      WriteLog(lr);
   }

   err = 0;
   bool savedB = SaveDMCState("B", stateB, err);
   if(!savedB)
   {
      PrintFormat("SaveDMCState(%s) err=%d %s", "B", err, ErrorDescriptionWrap(err));
      LogRecord lr;
      lr.Time       = TimeCurrent();
      lr.Symbol     = Symbol();
      lr.System     = "B";
      lr.Reason     = "DEINIT";
      lr.Spread     = PriceToPips(MathAbs(Ask - Bid));
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
      lr.ErrorCode  = err;
      lr.ErrorInfo  = ErrorDescriptionWrap(err);
      WriteLog(lr);
   }
}

