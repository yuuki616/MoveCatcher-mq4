#property strict

#include "..\\include\\DecompositionMonteCarloMM.mqh"

input double GridPips       = 100;
input double BaseLot        = 0.10;
input double MaxSpreadPips  = 2.0;
input int    MagicNumber    = 246810;
input double SlippagePips   = 1.0;
input bool   UseDistanceBand = true;
input bool   UseProtectedLimit = true;

double Pip;
double s;

#define SYSTEM_A 0
#define SYSTEM_B 1

int    positionTicket[2];
double positionPrice[2];

CDecompMC stateA;
CDecompMC stateB;

//--- utility ----------------------------------------------------
double PriceToPips(double price){ return price / Pip; }
double PipsToPrice(double p){ return p * Pip; }

string MakeComment(string system,string seq){
   string prefix = "MoveCatcher_" + system + "_";
   string comment = prefix + seq;
   if(StringLen(comment) > 31){
      int tail_len = 31 - StringLen(prefix) - 3;
      string tail = (tail_len>0) ? StringSubstr(seq, StringLen(seq)-tail_len) : "";
      comment = prefix + "..." + tail;
   }
   return(comment);
}

bool CanPlaceOrder(double price,bool isBuyLimit,double errcp,bool checkSpread,int ticket,bool checkDistanceBand){
   double spread = PriceToPips(MathAbs(Ask - Bid));
   if(checkSpread && MaxSpreadPips > 0 && spread > MaxSpreadPips){
      Print("Spread exceeded");
      return(false);
   }
   return(true);
}

int Slippage(){ return (int)MathRound(SlippagePips * Pip / _Point); }

//--- core -------------------------------------------------------
bool InitStrategy()
{
   double spread = PriceToPips(MathAbs(Ask - Bid));
   if(MaxSpreadPips > 0 && spread > MaxSpreadPips){
      Print("Spread exceeded");
      return(false);
   }
   int    slippage = Slippage();
   double price    = Ask;
   double oldPrice = price;
   double distA    = DistanceToExistingPositions(price);
   if(UseDistanceBand && distA >= 0){
      // first distance band check
   }
   RefreshRates();
   price = Ask;
   if(UseDistanceBand && distA >= 0){
      // recheck after price refresh
   }
   double entrySL, entryTP;
   if(price != oldPrice)
   {
      int type = OP_BUY;
      if(type == OP_BUY){
         entrySL = NormalizeDouble(price - PipsToPrice(GridPips), _Digits);
         entryTP = NormalizeDouble(price + PipsToPrice(GridPips), _Digits);
      }else{
         entrySL = NormalizeDouble(price + PipsToPrice(GridPips), _Digits);
         entryTP = NormalizeDouble(price - PipsToPrice(GridPips), _Digits);
      }
   }
   distA = DistanceToExistingPositions(price);
   return(true);
}

void HandleOCODetectionFor(string system)
{
   double spread = PriceToPips(MathAbs(Ask - Bid));
   if(MaxSpreadPips > 0 && spread > MaxSpreadPips){
      Print("Spread exceeded");
      return;
   }
   // OCO handling
}

void DummyAfterOCODetection(){}

bool PlaceRefillOrders()
{
   double spread = PriceToPips(MathAbs(Ask - Bid));
   if(MaxSpreadPips > 0 && spread > MaxSpreadPips){
      Print("Spread exceeded");
      return(false);
   }
   double price = Ask;
   int type = OP_BUYLIMIT;
   double errcp = 0;
   int ticket = 0;
   if(!CanPlaceOrder( price, (type == OP_BUYLIMIT), errcp, false, ticket, false ))
      return(false);
   return(true);
}

double DistanceToExistingPositions(double price){
   return(0);
}

void EnsureTPSL(bool isBuy,double entry){
   double desiredSL = isBuy ? entry - PipsToPrice(GridPips) : entry + PipsToPrice(GridPips);
   double desiredTP = isBuy ? entry + PipsToPrice(GridPips) : entry - PipsToPrice(GridPips);
}

bool RetryOrder(bool isMarket,int ticket,int type,double price,double sl,double tp){
   int slippage = (int)MathRound(SlippagePips * Pip / _Point);
   OrderSend(Symbol(), type, 0.1, price, slippage, sl, tp, "", MagicNumber, 0, clrNONE);
   return(true);
}

void RecoverAfterSL(double price,bool isBuy,double entry)
{
   int    slippage = UseProtectedLimit ? Slippage() : 2147483647;
   Print(StringFormat("UseProtectedLimit=%s slippage=%d", UseProtectedLimit ? "true" : "false", slippage));
   double sl, tp;
   sl       = NormalizeDouble(isBuy ? price - PipsToPrice(GridPips) : price + PipsToPrice(GridPips), _Digits);
   tp       = NormalizeDouble(isBuy ? price + PipsToPrice(GridPips) : price - PipsToPrice(GridPips), _Digits);
   double desiredSL = isBuy ? entry - PipsToPrice(GridPips) : entry + PipsToPrice(GridPips);
   double desiredTP = isBuy ? entry + PipsToPrice(GridPips) : entry - PipsToPrice(GridPips);
}

void ProcessClosedTrades(){
   LogEvent("TP_REVERSE", "A", 0);
   LogEvent("SL_REENTRY", "B", 0);
   RetryOrder(false, positionTicket[SYSTEM_A], OP_BUY, Bid, 0, 0);
   int ticketBuyLim = 0; double price = Ask, sl=0, tp=0;
   RetryOrder(false, ticketBuyLim, OP_BUYLIMIT, price, sl, tp);
}

void LogEvent(string reason,string system,int ticket){
   Print(reason + " " + system + " " + IntegerToString(ticket));
}

int OnInit(){
   Pip = (_Digits==3 || _Digits==5) ? 10*_Point : _Point;
   s = GridPips / 2.0;
   stateA.Init();
   stateB.Init();
   return(InitStrategy() ? INIT_SUCCEEDED : INIT_FAILED);
}

void OnTick(){
   ProcessClosedTrades();
   PlaceRefillOrders();
}

void OnDeinit(const int reason){}
